"""League radar, capital plan and matchday review (Home Assistant only, read-only).

Not part of the 1:1 planner port with the macOS app.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta

from .lineup import Matchday
from .models import Manager, MVPoint, Player, PlayerForm, Transfer
from .planner import market_value_at

# ---- league radar ------------------------------------------------------------------


@dataclass
class RivalInfo:
    manager: Manager
    is_me: bool
    gap_to_first: float
    gap_to_above: float | None  # None for the leader
    injured_starters: list[str] = field(default_factory=list)  # names; unknown for me → []


def league_radar(
    managers: list[Manager], my_id: str, squads: dict[str, list[Player]]
) -> list[RivalInfo]:
    ordered = sorted(managers, key=lambda m: m.placement)
    if not ordered:
        return []
    top = max(m.season_points for m in ordered)
    result: list[RivalInfo] = []
    for i, m in enumerate(ordered):
        above = ordered[i - 1].season_points - m.season_points if i > 0 else None
        squad = {p.id: p for p in squads.get(m.id, [])}
        injured = [
            squad[pid].full_name for pid in m.lineup_ids if pid in squad and not squad[pid].is_fit
        ]
        result.append(RivalInfo(m, m.id == my_id, top - m.season_points, above, injured))
    return result


# ---- capital plan -----------------------------------------------------------------


class CapitalRules:
    growth_days = 14  # daily growth = squad value change over the last 14 days / 14
    winter_gap_days = 14  # a break between matchdays longer than this is the winter break


@dataclass
class CapitalPlan:
    capital: float  # budget + team value
    daily_growth: float
    winter_break: datetime | None
    season_end: datetime | None
    capital_winter: float | None
    capital_end: float | None
    buying_power: float  # bid limit until Friday (from the plan)
    buying_power_winter: float | None


def capital_plan(
    *,
    budget: float,
    squad: list[Player],
    history: dict[str, list[MVPoint]],
    matchdays: list[Matchday],
    bid_limit: float,
    now: datetime,
) -> CapitalPlan:
    team_value = sum(p.market_value for p in squad)
    past = now - timedelta(days=CapitalRules.growth_days)
    then = 0.0
    for p in squad:
        h = history.get(p.id, [])
        then += (market_value_at(h, past) if h else None) or p.market_value
    daily = (team_value - then) / CapitalRules.growth_days

    starts = sorted((min(m.kickoff for m in d.matches), max(m.kickoff for m in d.matches)) for d in matchdays)
    winter = None
    for (s1, e1), (s2, _) in zip(starts, starts[1:]):
        if e1 > now and (s2 - e1).days > CapitalRules.winter_gap_days:
            winter = e1
            break
    end = starts[-1][1] if starts and starts[-1][1] > now else None

    def ahead(when: datetime | None, base: float) -> float | None:
        return base + daily * max(0.0, (when - now).total_seconds() / 86_400) if when else None

    capital = budget + team_value
    return CapitalPlan(
        capital=capital,
        daily_growth=daily,
        winter_break=winter,
        season_end=end,
        capital_winter=ahead(winter, capital),
        capital_end=ahead(end, capital),
        buying_power=bid_limit,
        buying_power_winter=ahead(winter, bid_limit),
    )


# ---- matchday review ---------------------------------------------------------------

# Formations allowed by Kickbase (defenders-midfielders-forwards, always 1 goalkeeper).
FORMATIONS = [(3, 4, 3), (3, 5, 2), (4, 2, 4), (4, 3, 3), (4, 4, 2), (4, 5, 1), (5, 3, 2), (5, 4, 1)]


@dataclass
class MatchdayReview:
    matchday: int
    points: float
    matchday_placement: int | None
    placement: int
    gap_to_first: float
    best_points: float
    best_formation: str
    missed: list[str]  # bench players that would have been in the best eleven
    buys: list[tuple[str, float]]  # (name, market value change since purchase) – last 7 days


def best_eleven(squad: list[Player], points: dict[str, float]) -> tuple[float, str, list[Player]]:
    by_pos: dict[int, list[Player]] = {}
    for p in squad:
        by_pos.setdefault(p.position, []).append(p)
    for v in by_pos.values():
        v.sort(key=lambda p: points.get(p.id, 0.0), reverse=True)
    best: tuple[float, str, list[Player]] = (0.0, "", [])
    for d, m, f in FORMATIONS:
        need = {1: 1, 2: d, 3: m, 4: f}
        if any(len(by_pos.get(pos, [])) < n for pos, n in need.items()):
            continue
        xi = [p for pos, n in need.items() for p in by_pos[pos][:n]]
        total = sum(points.get(p.id, 0.0) for p in xi)
        if total > best[0] or not best[1]:
            best = (total, f"{d}-{m}-{f}", xi)
    return best


def matchday_review(
    *,
    matchday: int,
    me: Manager,
    managers: list[Manager],
    squad: list[Player],
    forms: dict[str, PlayerForm],
    transfers: list[Transfer],
    my_id: str,
    now: datetime,
) -> MatchdayReview:
    # /lineup `ph[0]` = points of the matchday that just finished.
    points = {pid: (f.recent[0] or 0.0) if f.recent else 0.0 for pid, f in forms.items()}
    total, formation, xi = best_eleven(squad, points)
    starters = {p.id for p in squad if p.lineup_slot is not None}
    missed = [p.full_name for p in xi if p.id not in starters and points.get(p.id, 0.0) > 0]
    squad_by_id = {p.id: p for p in squad}
    week = now - timedelta(days=7)
    buys = [
        (t.player_name, squad_by_id[t.player_id].market_value - t.price)
        for t in transfers
        if t.buyer_id == my_id and t.date >= week and t.player_id in squad_by_id
    ]
    top = max((m.season_points for m in managers), default=me.season_points)
    return MatchdayReview(
        matchday=matchday,
        points=me.matchday_points,
        matchday_placement=me.matchday_placement,
        placement=me.placement,
        gap_to_first=top - me.season_points,
        best_points=max(total, me.matchday_points),
        best_formation=formation,
        missed=missed,
        buys=buys,
    )


def last_finished_matchday(matchdays: list[Matchday]) -> int | None:
    """Highest matchday whose matches are all finished."""
    done = [d.day for d in matchdays if d.matches and all(m.status == 2 for m in d.matches)]
    return max(done, default=None)

