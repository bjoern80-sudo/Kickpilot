"""Transfer automation – 1:1 port of AutoTransfer.swift (macOS app).

Pure Python, no Home Assistant imports, so it can be tested on its own.
Keep the rules in sync with AutoTransfer.swift when they change.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import hashlib
import math
from zoneinfo import ZoneInfo

from .models import Manager, MVPoint, Player, Transfer

BERLIN = ZoneInfo("Europe/Berlin")


class AutoRules:
    max_squad_size = 18
    max_per_club = 3
    # Minimum players per position that must always stay (1 TW, 2 ABW, 3 MIT, 4 ST).
    min_per_position = {1: 1, 2: 3, 4: 1}
    keep_core = 11
    kickbase_sale_factor = 1.0
    bid_margin_pct = 1.0
    default_overpay_pct = 3.0
    min_samples = 3
    momentum_days = 3.0
    hold_days = 3.0
    min_rising_days = 4
    min_profit_pct = 5.0
    min_profit = 100_000.0
    reversal_window = 6
    reversal_min_rises = 2
    reversal_min_drop_pct = 5.0
    peak_lookback_days = 30
    rise_tolerance_pct = 0.5
    backtest_days = 120
    # Budget deadline: every Friday 20:30 (German time). Purchases that complete after it
    # count for the following week and may push the budget below zero again right away.
    deadline_weekday = 4  # Friday (Python: Monday = 0)
    deadline_hour = 20
    deadline_minute = 30
    # Kickbase updates all market values once a day at 22:00 (German time).
    market_value_update_hour = 22
    max_debt_share_of_team_value = 0.30
    deadline_warning_hours = 6.0


POSITION_NAMES = {1: "Torhüter", 2: "Abwehrspieler", 3: "Mittelfeldspieler", 4: "Stürmer"}


def next_deadline(now: datetime | None = None) -> datetime:
    """Next Friday 20:30 Europe/Berlin (today if it is Friday before 20:30)."""
    now = (now or datetime.now(timezone.utc)).astimezone(BERLIN)
    days = (AutoRules.deadline_weekday - now.weekday()) % 7
    candidate = (now + timedelta(days=days)).replace(
        hour=AutoRules.deadline_hour, minute=AutoRules.deadline_minute, second=0, microsecond=0
    )
    if candidate <= now:
        candidate += timedelta(days=7)
    return candidate


def market_value_at(history: list[MVPoint], date: datetime) -> float | None:
    """Market value on a given day from a (sorted ascending) history."""
    last = None
    for p in history:
        if p.date <= date:
            last = p
        else:
            break
    if last is not None:
        return last.value
    return history[0].value if history else None


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    s = sorted(values)
    # Swift's .rounded() rounds half away from zero.
    idx = min(len(s) - 1, max(0, math.floor((len(s) - 1) * p + 0.5)))
    return s[idx]


def round_bid(raw: float) -> float:
    """Odd amount just above a round number beats "round" bids of others."""
    return math.ceil(raw / 10_000) * 10_000 + 1_111


def history_with_current(h: list[MVPoint], current: float, now: datetime) -> list[MVPoint]:
    """History with today's market value appended – only if it is a new value.

    Kickbase updates market values once a day at 22:00; before that the current value
    equals the last history point and appending it would fake a "flat" day.
    """
    if current <= 0:
        return h
    if not h:
        return [MVPoint(now, current)]
    last = h[-1]
    if abs(last.value - current) < 1:
        return h
    if last.date.astimezone(BERLIN).date() == now.astimezone(BERLIN).date():
        return h[:-1] + [MVPoint(last.date, current)]
    return h + [MVPoint(now, current)]


# ---- bidder profiles ---------------------------------------------------------


@dataclass
class BidderProfile:
    id: str
    name: str
    samples: int
    median_overpay: float | None
    typical_high_overpay: float | None
    max_overpay: float | None
    buys_per_week: float

    @property
    def is_reliable(self) -> bool:
        return self.samples >= AutoRules.min_samples

    @property
    def expected_overpay(self) -> float:
        value = self.typical_high_overpay if self.is_reliable else None
        return value if value is not None else AutoRules.default_overpay_pct

    @classmethod
    def build(
        cls,
        manager: Manager,
        transfers: list[Transfer],
        history: dict[str, list[MVPoint]],
        now: datetime,
    ) -> BidderProfile:
        buys = [t for t in transfers if t.buyer_id == manager.id]
        ratios: list[float] = []
        for t in buys:
            h = history.get(t.player_id)
            if not h:
                continue
            mv = market_value_at(h, t.date)
            if mv and mv > 0:
                ratios.append((t.price / mv - 1) * 100)
        if transfers:
            oldest = min(t.date for t in transfers)
            weeks = max(1.0, (now - oldest).total_seconds() / (7 * 86_400))
            per_week = len(buys) / weeks
        else:
            per_week = 0.0
        return cls(
            id=manager.id,
            name=manager.name,
            samples=len(ratios),
            median_overpay=percentile(ratios, 0.5),
            typical_high_overpay=percentile(ratios, 0.75),
            max_overpay=max(ratios) if ratios else None,
            buys_per_week=per_week,
        )


# ---- trend -------------------------------------------------------------------

STEADY_RISE = "stabiler Anstieg"
REVERSAL = "Trendumkehr"
NO_PATTERN = "kein Muster"


@dataclass(frozen=True)
class TrendEvaluation:
    pattern: str
    trough: float | None
    drop_before_trough_pct: float | None
    current: float
    daily_gain: float
    momentum_pct: float
    rising_days: int
    peak: float | None
    peak_date: datetime | None
    expected_sale: float

    @classmethod
    def evaluate(cls, points: list[MVPoint]) -> TrendEvaluation | None:
        """points: daily history, ascending; the last point is "today"."""
        v = [p.value for p in points]
        n = len(v)
        back = int(AutoRules.momentum_days)
        if n < max(6, back + 1) or v[-1] <= 0:
            return None
        current = v[-1]

        base = v[n - 1 - back]
        daily_gain = (current - base) / back
        momentum_pct = (current / base - 1) * 100 if base > 0 else 0.0
        rising_days = sum(1 for i in range(n - 5, n) if v[i] > v[i - 1])

        # Trend reversal: recent bottom, clear fall before it, rising every day since.
        pattern = (
            STEADY_RISE
            if rising_days >= AutoRules.min_rising_days and momentum_pct > 0
            else NO_PATTERN
        )
        trough = None
        drop = None
        window = min(AutoRules.reversal_window, n - 1)
        if n >= 12:
            # first index of the minimum (Swift min(by:) keeps the first)
            t = min(range(n - window, n), key=lambda i: v[i])
            if (
                n - 1 - t >= AutoRules.reversal_min_rises
                and all(v[i] > v[i - 1] for i in range(t + 1, n))
                and t > max(0, t - 10)
                and v[t] > 0
            ):
                before = max(v[max(0, t - 10) : t])
                fell = (before / v[t] - 1) * 100
                if fell >= AutoRules.reversal_min_drop_pct:
                    trough = v[t]
                    drop = fell
                    if pattern == NO_PATTERN:
                        pattern = REVERSAL
                        daily_gain = (current - v[t]) / (n - 1 - t)

        # Walk back to the start of the current rising phase (small dips tolerated).
        start = n - 1
        while start > 0 and v[start - 1] <= v[start] * (1 + AutoRules.rise_tolerance_pct / 100):
            start -= 1
        peak = None
        peak_date = None
        look_from = max(0, start - AutoRules.peak_lookback_days)
        if start > 0 and look_from < start:
            # first index of the maximum (like Swift's max(by:))
            idx = look_from
            for i in range(look_from, start):
                if v[i] > v[idx]:
                    idx = i
            peak = v[idx]
            peak_date = points[idx].date

        projected = current + max(0.0, daily_gain) * AutoRules.hold_days
        if peak is None:
            expected_sale = current
        else:
            expected_sale = min(peak, projected) if peak > current else current
        return cls(
            pattern=pattern,
            trough=trough,
            drop_before_trough_pct=drop,
            current=current,
            daily_gain=daily_gain,
            momentum_pct=momentum_pct,
            rising_days=rising_days,
            peak=peak,
            peak_date=peak_date,
            expected_sale=expected_sale,
        )


def fmt_mio(value: float) -> str:
    return f"{value / 1_000_000:.1f} Mio. €".replace(".", ",")


def fmt_signed_eur(value: float) -> str:
    sign = "+" if value >= 0 else "−"
    return f"{sign}{abs(value):,.0f} €".replace(",", ".")


def bid_check(t: TrendEvaluation, bid: float, is_fit: bool) -> tuple[bool, float | str]:
    """(True, profit) or (False, reason) – the buy rules shared by planning and backtest."""
    if not is_fit:
        return False, "nicht fit"
    if t.pattern == NO_PATTERN:
        return False, (
            f"weder stabiler Anstieg ({t.rising_days}/5 Tage) noch Trendumkehr"
            if t.daily_gain > 0
            else "kein Aufwärtstrend"
        )
    if t.peak is None:
        return False, "zu wenig Verlauf für einen Hochpunkt"
    if t.peak <= t.current:
        return False, f"liegt schon über dem letzten Hochpunkt ({fmt_mio(t.peak)})"
    profit = t.expected_sale - bid
    required = max(AutoRules.min_profit, bid * AutoRules.min_profit_pct / 100)
    if profit < required:
        return False, f"Gewinn bis Hochpunkt zu klein ({fmt_signed_eur(profit)})"
    return True, profit


# ---- backtest ----------------------------------------------------------------


@dataclass
class BacktestStats:
    signals: int = 0
    wins: int = 0
    total_profit_pct: float = 0.0
    target_reached: int = 0

    @property
    def hit_rate(self) -> float:
        return self.wins / self.signals * 100 if self.signals else 0.0

    @property
    def avg_profit_pct(self) -> float:
        return self.total_profit_pct / self.signals if self.signals else 0.0

    def add(self, bid: float, sold: float, target: float) -> None:
        self.signals += 1
        if sold > bid:
            self.wins += 1
        if sold >= target:
            self.target_reached += 1
        self.total_profit_pct += (sold / bid - 1) * 100


@dataclass
class BacktestResult:
    all: BacktestStats = field(default_factory=BacktestStats)
    steady: BacktestStats = field(default_factory=BacktestStats)
    reversal: BacktestStats = field(default_factory=BacktestStats)

    @classmethod
    def run(cls, histories: list[list[MVPoint]], premium_pct: float) -> BacktestResult:
        r = cls()
        hold = int(AutoRules.hold_days)
        for h in histories:
            if len(h) <= 30:
                continue
            first_day = max(10, len(h) - AutoRules.backtest_days)
            for d in range(first_day, len(h) - hold):
                t = TrendEvaluation.evaluate(h[: d + 1])
                if t is None:
                    continue
                bid = round_bid(t.current * (1 + premium_pct / 100))
                ok, _ = bid_check(t, bid, True)
                if not ok:
                    continue
                sold = h[d + hold].value
                r.all.add(bid, sold, t.expected_sale)
                (r.reversal if t.pattern == REVERSAL else r.steady).add(bid, sold, t.expected_sale)
        return r


# ---- plan --------------------------------------------------------------------


@dataclass
class BuyProposal:
    player: Player
    bid: float
    momentum_pct: float
    competitor_pct: float
    competitor_name: str
    expected_gain: float
    trend: TrendEvaluation
    after_deadline: bool

    @property
    def bid_over_mv_pct(self) -> float:
        mv = self.player.market_value
        return (self.bid / mv - 1) * 100 if mv > 0 else 0.0


@dataclass
class SaleProposal:
    player: Player
    expected_proceeds: float
    gain_pct: float
    gain_basis: str


@dataclass
class SkippedCandidate:
    player: Player
    reason: str


@dataclass
class AutoPlan:
    buys: list[BuyProposal] = field(default_factory=list)
    skipped: list[SkippedCandidate] = field(default_factory=list)
    sales: list[SaleProposal] = field(default_factory=list)
    reserve: float = 0.0
    bid_limit: float = 0.0
    global_limit: float = 0.0
    debt_limit: float = 0.0
    all_open_bids: float = 0.0
    open_bids: float = 0.0
    deadline: datetime = field(default_factory=next_deadline)
    budget_after_sales: float = 0.0
    committed_budget: float = 0.0
    competitor_pct: float = AutoRules.default_overpay_pct
    competitor_name: str = "–"
    backtest: BacktestResult = field(default_factory=BacktestResult)
    created: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def recommended_bid(self, p: Player) -> float:
        return round_bid(
            max(
                p.market_value * (1 + (self.competitor_pct + AutoRules.bid_margin_pct) / 100),
                p.effective_price,
            )
        )

    @property
    def total_bids(self) -> float:
        return sum(b.bid for b in self.buys)

    @property
    def buys_id(self) -> str:
        return _hash("B", [f"{b.player.id}:{int(b.bid)}" for b in self.buys])

    @property
    def sales_id(self) -> str:
        return _hash("S", [s.player.id for s in self.sales])


def _hash(prefix: str, parts: list[str]) -> str:
    if not parts:
        return ""
    digest = hashlib.sha1("|".join(sorted(parts)).encode()).hexdigest()[:8]
    return f"{prefix}{digest}"


def make_plan(
    *,
    budget: float,
    squad: list[Player],
    market: list[Player],
    my_user_id: str,
    transfers: list[Transfer],
    profiles: list[BidderProfile],
    history: dict[str, list[MVPoint]],
    backtest: BacktestResult | None = None,
    now: datetime | None = None,
) -> AutoPlan:
    """Same logic as AutoPlanner.plan in the macOS app. Read-only."""
    now = now or datetime.now(timezone.utc)
    plan = AutoPlan(created=now)
    plan.deadline = next_deadline(now)
    far = datetime.max.replace(tzinfo=timezone.utc)

    # Open bids that may still win before the deadline count as already spent.
    plan.open_bids = sum(
        p.my_offer_price for p in market if p.my_offer_price and (p.expires_at or far) <= plan.deadline
    )
    committed = budget - plan.open_bids
    plan.committed_budget = committed

    team_value = sum(p.market_value for p in squad)
    plan.debt_limit = team_value * AutoRules.max_debt_share_of_team_value
    plan.all_open_bids = sum(p.my_offer_price for p in market if p.my_offer_price)
    plan.global_limit = max(0.0, budget - plan.all_open_bids + plan.debt_limit)

    # Players outside the best 11 (Ø points) can be sold to Kickbase on Friday.
    by_avg = sorted(squad, key=lambda p: p.average_points, reverse=True)
    core = {p.id for p in by_avg[: AutoRules.keep_core]}
    plan.reserve = sum(
        p.market_value * AutoRules.kickbase_sale_factor for p in squad if p.id not in core
    )
    plan.bid_limit = max(0.0, committed + plan.reserve)

    rivals = [p for p in profiles if p.id != my_user_id]
    strongest = None
    for p in rivals:  # first of equal maxima, like Swift's max(by:)
        if strongest is None or p.expected_overpay > strongest.expected_overpay:
            strongest = p
    plan.competitor_pct = strongest.expected_overpay if strongest else AutoRules.default_overpay_pct
    plan.competitor_name = strongest.name if strongest else "–"

    pending = [p for p in market if p.my_offer_price is not None]
    squad_count = len(squad) + len(pending)
    per_club: dict[str, int] = {}
    for p in squad + pending:
        per_club[p.team_id] = per_club.get(p.team_id, 0) + 1
    remaining = plan.bid_limit
    global_remaining = plan.global_limit

    plan.backtest = backtest or BacktestResult.run(
        list(history.values()), plan.competitor_pct + AutoRules.bid_margin_pct
    )

    evaluated = []
    for p in market:
        if p.seller_user_id == my_user_id or p.market_value <= 0:
            continue
        h = history_with_current(history.get(p.id, []), p.market_value, now)
        t = TrendEvaluation.evaluate(h)
        if t is None:
            plan.skipped.append(SkippedCandidate(p, "kein Marktwertverlauf"))
            continue
        bid = plan.recommended_bid(p)
        evaluated.append((p, t, bid, bid_check(t, bid, p.is_fit)))
    evaluated.sort(key=lambda e: e[3][1] if e[3][0] else -math.inf, reverse=True)

    open_bid_ids = {p.id for p in pending}
    for p, trend, bid, (ok, result) in evaluated:
        if not ok:
            plan.skipped.append(SkippedCandidate(p, str(result)))
            continue
        ends = p.expires_at or far
        after_deadline = ends > plan.deadline

        # Only bid on the day the listing ends: by then the trend is more reliable.
        ends_today = (
            p.expires_at is not None
            and p.expires_at.astimezone(BERLIN).date() == now.astimezone(BERLIN).date()
        )

        if p.id in open_bid_ids:
            plan.skipped.append(SkippedCandidate(p, "Du hast schon geboten"))
        elif not ends_today:
            plan.skipped.append(SkippedCandidate(p, "Angebot endet nicht heute"))
        elif squad_count >= AutoRules.max_squad_size:
            plan.skipped.append(SkippedCandidate(p, f"Kader voll ({AutoRules.max_squad_size})"))
        elif per_club.get(p.team_id, 0) >= AutoRules.max_per_club:
            plan.skipped.append(
                SkippedCandidate(p, f"Schon {AutoRules.max_per_club} Spieler dieses Vereins")
            )
        elif bid > global_remaining:
            pct = int(AutoRules.max_debt_share_of_team_value * 100)
            plan.skipped.append(SkippedCandidate(p, f"Über der Minus-Grenze (−{pct} % Teamwert)"))
        elif not after_deadline and bid > remaining:
            plan.skipped.append(SkippedCandidate(p, "Nicht bis Freitag ausgleichbar"))
        else:
            plan.buys.append(
                BuyProposal(
                    player=p,
                    bid=bid,
                    momentum_pct=trend.momentum_pct,
                    competitor_pct=plan.competitor_pct,
                    competitor_name=plan.competitor_name,
                    expected_gain=float(result),
                    trend=trend,
                    after_deadline=after_deadline,
                )
            )
            squad_count += 1
            per_club[p.team_id] = per_club.get(p.team_id, 0) + 1
            global_remaining -= bid
            if not after_deadline:
                remaining -= bid
    plan.buys.sort(key=lambda b: b.expected_gain, reverse=True)

    plan.sales = sale_proposals(
        budget=committed,
        squad=squad,
        core=core,
        my_user_id=my_user_id,
        transfers=transfers,
        history=history,
        now=now,
    )
    plan.budget_after_sales = committed + sum(s.expected_proceeds for s in plan.sales)
    return plan


def sale_proposals(
    *,
    budget: float,
    squad: list[Player],
    core: set[str],
    my_user_id: str,
    transfers: list[Transfer],
    history: dict[str, list[MVPoint]],
    now: datetime,
) -> list[SaleProposal]:
    """Weakest players with the best value gain, until the budget is ≥ 0."""
    if budget >= 0:
        return []

    last_buy: dict[str, Transfer] = {}
    for t in transfers:
        if t.buyer_id != my_user_id:
            continue
        if t.player_id not in last_buy or t.date > last_buy[t.player_id].date:
            last_buy[t.player_id] = t
    week_ago = now - timedelta(days=7)

    def gain(p: Player) -> tuple[float, str]:
        g = p.gain_since_purchase
        if g is not None and p.market_value - g > 0:
            return g / (p.market_value - g) * 100, "seit Kauf"
        t = last_buy.get(p.id)
        if t and t.price > 0:
            return (p.market_value / t.price - 1) * 100, "ggü. Kaufpreis"
        h = history.get(p.id)
        if h:
            then = market_value_at(h, week_ago)
            if then and then > 0:
                return (p.market_value / then - 1) * 100, "7 Tage"
        return 0.0, "unbekannt"

    by_points = [p.id for p in sorted(squad, key=lambda p: p.average_points)]
    by_gain = [p.id for p in sorted(squad, key=lambda p: gain(p)[0], reverse=True)]

    def rank(p: Player) -> int:
        return by_points.index(p.id) + by_gain.index(p.id)

    ordered = sorted((p for p in squad if p.id not in core), key=rank) + sorted(
        (p for p in squad if p.id in core), key=rank
    )

    result: list[SaleProposal] = []
    balance = budget
    per_position: dict[int, int] = {}
    for p in squad:
        per_position[p.position] = per_position.get(p.position, 0) + 1
    for p in ordered:
        if balance >= 0:
            break
        minimum = AutoRules.min_per_position.get(p.position, 0)
        if per_position.get(p.position, 0) <= minimum:
            continue
        per_position[p.position] -= 1
        proceeds = p.market_value * AutoRules.kickbase_sale_factor
        g = gain(p)
        result.append(SaleProposal(p, proceeds, g[0], g[1]))
        balance += proceeds
    return result


# ---- injury warning -------------------------------------------------------------
# Same as InjuryAlert in AutoTransfer.swift. Kickbase updates market values at 22:00;
# an injured player usually loses value from the next update on, so selling before
# 22:00 still brings today's market value (100 % on a sale to Kickbase).

INJURED_STATUS = 1  # `st` 1 = verletzt


@dataclass
class InjuryAlert:
    player: Player
    proceeds: float
    sellable: bool
    reason: str  # why a sale is not possible, otherwise ""
    in_core: bool  # among the best 11 by Ø points


def injury_alerts(squad: list[Player], known_injured: set[str]) -> list[InjuryAlert]:
    """Own players newly reported injured since the last check (`known_injured`)."""
    by_avg = sorted(squad, key=lambda p: p.average_points, reverse=True)
    core = {p.id for p in by_avg[: AutoRules.keep_core]}
    per_position: dict[int, int] = {}
    for p in squad:
        per_position[p.position] = per_position.get(p.position, 0) + 1
    result: list[InjuryAlert] = []
    for p in by_avg:
        if p.status != INJURED_STATUS or p.id in known_injured:
            continue
        minimum = AutoRules.min_per_position.get(p.position, 0)
        sellable = per_position.get(p.position, 0) > minimum
        reason = "" if sellable else f"Mindestbesetzung ({minimum} {p.position_name})"
        result.append(
            InjuryAlert(p, p.market_value * AutoRules.kickbase_sale_factor, sellable, reason, p.id in core)
        )
    return result


def injured_ids(squad: list[Player]) -> set[str]:
    return {p.id for p in squad if p.status == INJURED_STATUS}
