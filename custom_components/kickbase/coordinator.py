"""Data coordinator.

* Every `scan_interval` minutes: budget, squad, market, ranking (+ plan recomputed).
* Once a day at `mv_fetch_time` (and on first start): transfers of all managers and
  market value histories, cached in .storage so a restart does not reload everything.
* At `check_times` / Friday `friday_times`: event `kickbase_vorschlaege`.
* Season schedule (kick-off times) every few hours → lineup check before kick-off.
Nothing here executes transactions.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import logging
import time

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import CALLBACK_TYPE, HomeAssistant, callback
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.event import async_track_time_change
from homeassistant.helpers.storage import Store
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed
from homeassistant.util import dt as dt_util

from .api import KickbaseApi, KickbaseAuthError, KickbaseError
from .const import (
    CONF_LEAGUE_ID,
    DOMAIN,
    OPT_CHECK_TIMES,
    OPT_FRIDAY_TIMES,
    OPT_MV_FETCH_TIME,
    OPT_SCAN_INTERVAL,
    OPT_WARNING_HOURS,
    opt,
    parse_times,
)
from .insights import CapitalPlan, RivalInfo, capital_plan, last_finished_matchday, league_radar
from .lineup import LineupCheck, Matchday, check_lineup, current_matchday
from .models import Manager, ManagerTransferEntry, MVPoint, Player, PlayerForm, Transfer
from .planner import (
    AutoPlan,
    AutoRules,
    BacktestResult,
    BidderProfile,
    Fixture,
    TrendSale,
    UpgradeProposal,
    forecast_points,
    make_plan,
    next_deadline,
    trend_sales,
    upgrade_proposals,
)

_LOGGER = logging.getLogger(__name__)

EVENT_PROPOSALS = f"{DOMAIN}_vorschlaege"
TRANSFER_PAGES = 4
TRANSFER_PAGE_SIZE = 25
PARALLEL = 4
HISTORY_KEEP_DAYS = 200
HISTORY_MAX_AGE = timedelta(hours=26)
SCHEDULE_MAX_AGE = timedelta(hours=3)
TABLE_MAX_AGE = timedelta(hours=6)
FORM_MAX_AGE = timedelta(hours=6)
RIVALS_MAX_AGE = timedelta(hours=1)
STORE_VERSION = 1


@dataclass
class KickbaseData:
    budget: float = 0.0
    squad: list[Player] = field(default_factory=list)
    market: list[Player] = field(default_factory=list)
    managers: list[Manager] = field(default_factory=list)
    my_user_id: str = ""
    updated: datetime | None = None
    plan: AutoPlan | None = None
    profiles: list[BidderProfile] = field(default_factory=list)
    history_loaded_at: datetime | None = None
    transfer_count: int = 0
    team_names: dict[str, str] = field(default_factory=dict)
    lineup: LineupCheck | None = None
    forecasts: dict[str, float] = field(default_factory=dict)  # player id → expected points
    forecast_matchday: int | None = None
    upgrades: list[UpgradeProposal] = field(default_factory=list)
    trend_sales: list[TrendSale] = field(default_factory=list)
    radar: list[RivalInfo] = field(default_factory=list)
    capital: CapitalPlan | None = None
    forms: dict[str, PlayerForm] = field(default_factory=dict)  # own squad (/lineup)
    finished_matchday: int | None = None

    @property
    def team_value(self) -> float:
        return sum(p.market_value for p in self.squad)

    @property
    def me(self) -> Manager | None:
        return next((m for m in self.managers if m.id == self.my_user_id), None)


class KickbaseCoordinator(DataUpdateCoordinator[KickbaseData]):
    """Fetches the data and computes the plan (read-only)."""

    config_entry: ConfigEntry

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry, api: KickbaseApi) -> None:
        super().__init__(
            hass,
            _LOGGER,
            config_entry=entry,
            name=DOMAIN,
            update_interval=timedelta(minutes=opt(entry.options, OPT_SCAN_INTERVAL)),
        )
        self.api = api
        self.league_id: str = entry.data[CONF_LEAGUE_ID]
        self._store: Store = Store(hass, STORE_VERSION, f"{DOMAIN}_cache_{entry.entry_id}")
        self._entries: dict[str, list[ManagerTransferEntry]] = {}
        self._transfers: list[Transfer] = []
        self._history: dict[str, list[MVPoint]] = {}
        self._team_names: dict[str, str] = {}
        self._matchdays: list[Matchday] = []
        self._matchdays_at: datetime | None = None
        self._table: dict[str, tuple[str, int]] = {}
        self._table_at: datetime | None = None
        self._market_forms: dict[str, tuple[PlayerForm, datetime]] = {}
        self._rival_squads: dict[str, list[Player]] = {}
        self._rivals_at: datetime | None = None
        self._history_loaded_at: datetime | None = None
        self._history_lock = asyncio.Lock()
        self._backtest: BacktestResult | None = None
        self._backtest_key: tuple | None = None
        self._unsub: list[CALLBACK_TYPE] = []
        # Set by __init__.py: KickbaseAutomation.async_on_schedule
        self.on_schedule: Callable[[str], Awaitable[None]] | None = None
        self.automation = None  # KickbaseAutomation, set by __init__.py

    @property
    def transfers(self) -> list[Transfer]:
        return list(self._transfers)

    # ---- cache ------------------------------------------------------------

    async def async_load_cache(self) -> None:
        raw = await self._store.async_load()
        if not isinstance(raw, dict):
            return
        try:
            self._entries = {
                uid: [e for e in (ManagerTransferEntry.from_dict(d) for d in items) if e]
                for uid, items in raw.get("entries", {}).items()
            }
            self._history = {
                pid: [MVPoint(datetime.fromtimestamp(ts, timezone.utc), mv) for ts, mv in pts]
                for pid, pts in raw.get("history", {}).items()
            }
            loaded = raw.get("loaded_at")
            self._history_loaded_at = datetime.fromisoformat(loaded) if loaded else None
        except (TypeError, ValueError, KeyError) as err:
            _LOGGER.warning("Kickbase-Cache unbrauchbar, wird neu geladen: %s", err)
            self._entries, self._history, self._history_loaded_at = {}, {}, None
        self._transfers = Transfer.merge([e for v in self._entries.values() for e in v])

    async def _async_save_cache(self) -> None:
        cutoff = dt_util.utcnow() - timedelta(days=HISTORY_KEEP_DAYS)
        await self._store.async_save(
            {
                "entries": {uid: [e.to_dict() for e in v] for uid, v in self._entries.items()},
                "history": {
                    pid: [[int(p.date.timestamp()), p.value] for p in pts if p.date >= cutoff]
                    for pid, pts in self._history.items()
                },
                "loaded_at": self._history_loaded_at.isoformat() if self._history_loaded_at else None,
            }
        )

    # ---- schedule ---------------------------------------------------------

    @callback
    def async_setup_schedule(self) -> None:
        """Register the time triggers from the options."""
        options = self.config_entry.options
        (mv_h, mv_m), *_ = parse_times(opt(options, OPT_MV_FETCH_TIME)) or [(22, 30)]
        self._unsub.append(
            async_track_time_change(self.hass, self._handle_history_time, hour=mv_h, minute=mv_m, second=0)
        )
        for h, m in parse_times(opt(options, OPT_CHECK_TIMES)):
            self._unsub.append(
                async_track_time_change(self.hass, self._handle_check_time, hour=h, minute=m, second=5)
            )
        for h, m in parse_times(opt(options, OPT_FRIDAY_TIMES)):
            self._unsub.append(
                async_track_time_change(self.hass, self._handle_friday_time, hour=h, minute=m, second=10)
            )

    @callback
    def async_cancel_schedule(self) -> None:
        while self._unsub:
            self._unsub.pop()()

    async def _handle_history_time(self, now: datetime) -> None:
        if self.data:
            await self._background_history(self.data.managers)

    async def _handle_check_time(self, now: datetime) -> None:
        await self.async_refresh()
        self.fire_proposals("kaeufe")
        if self.on_schedule:
            await self.on_schedule("kaeufe")

    async def _handle_friday_time(self, now: datetime) -> None:
        if dt_util.as_local(now).weekday() != AutoRules.deadline_weekday:
            return
        await self.async_refresh()
        self.fire_proposals("verkaeufe")
        if self.on_schedule:
            await self.on_schedule("verkaeufe")

    @callback
    def fire_proposals(self, kind: str) -> None:
        """Event for notifications (phase 3) – only if there is something to do."""
        data = self.data
        plan = data.plan if data else None
        if plan is None:
            return
        if kind == "kaeufe" and plan.buys:
            self.hass.bus.async_fire(
                EVENT_PROPOSALS,
                {
                    "art": "kaeufe",
                    "plan_id": plan.buys_id,
                    "anzahl": len(plan.buys),
                    "summe": round(plan.total_bids),
                    "erwarteter_gewinn": round(sum(b.expected_gain for b in plan.buys)),
                    "spieler": [b.player.full_name for b in plan.buys],
                },
            )
        elif kind == "verkaeufe" and plan.sales:
            self.hass.bus.async_fire(
                EVENT_PROPOSALS,
                {
                    "art": "verkaeufe",
                    "plan_id": plan.sales_id,
                    "anzahl": len(plan.sales),
                    "erloes": round(sum(s.expected_proceeds for s in plan.sales)),
                    "budget_nach_geboten": round(plan.committed_budget),
                    "spieler": [s.player.full_name for s in plan.sales],
                },
            )

    def deadline_alert(self) -> bool:
        """Budget after bids negative and the Friday deadline is close."""
        plan = self.data.plan if self.data else None
        if plan is None:
            return False
        hours = (next_deadline() - dt_util.utcnow()).total_seconds() / 3600
        return plan.committed_budget < 0 and hours <= opt(self.config_entry.options, OPT_WARNING_HOURS)

    # ---- transfers & histories ---------------------------------------------

    async def async_refresh_history(self, managers: list[Manager] | None = None) -> None:
        """Reload transfers of all managers and all relevant market value histories."""
        async with self._history_lock:
            league = self.league_id
            if managers is None:
                managers = self.data.managers if self.data else await self.api.ranking(league)
            started = time.monotonic()
            sem = asyncio.Semaphore(PARALLEL)

            async def transfers_of(uid: str) -> tuple[str, list[ManagerTransferEntry] | None]:
                got: list[ManagerTransferEntry] = []
                try:
                    for page in range(TRANSFER_PAGES):
                        async with sem:
                            items = await self.api.manager_transfers(
                                league, uid, page * TRANSFER_PAGE_SIZE
                            )
                        got += items
                        if len(items) < TRANSFER_PAGE_SIZE:
                            break
                except KickbaseError as err:
                    _LOGGER.warning("Transfers von %s nicht geladen: %s", uid, err)
                    return uid, None
                return uid, got

            results = await asyncio.gather(*(transfers_of(m.id) for m in managers))
            for uid, got in results:
                if got is not None:
                    self._entries[uid] = got
            self._transfers = Transfer.merge([e for v in self._entries.values() for e in v])

            ids = {t.player_id for t in self._transfers if t.buyer_id}
            if self.data:
                ids |= {p.id for p in self.data.market} | {p.id for p in self.data.squad}
            await self._load_histories(ids, force=True)
            self._history_loaded_at = dt_util.utcnow()
            self._backtest_key = None
            await self._async_save_cache()
            _LOGGER.info(
                "Kickbase: %d Transfers, %d Marktwertverläufe in %.0f s geladen",
                len(self._transfers),
                len(self._history),
                time.monotonic() - started,
            )

    async def _background_history(self, managers: list[Manager]) -> None:
        try:
            await self.async_refresh_history(managers)
        except KickbaseError as err:
            _LOGGER.warning("Kickbase: Transfers/Marktwerte nicht geladen: %s", err)
            return
        await self.async_request_refresh()

    async def _load_histories(self, ids: set[str], force: bool) -> None:
        missing = [pid for pid in ids if force or pid not in self._history]
        if not missing:
            return
        sem = asyncio.Semaphore(PARALLEL)

        async def one(pid: str) -> None:
            async with sem:
                try:
                    self._history[pid] = await self.api.market_value_history(self.league_id, pid)
                except KickbaseError as err:
                    _LOGGER.debug("Marktwertverlauf %s nicht geladen: %s", pid, err)

        await asyncio.gather(*(one(pid) for pid in missing))

    # ---- regular update -----------------------------------------------------

    async def _async_update_data(self) -> KickbaseData:
        league = self.league_id
        try:
            budget, squad, market, managers = await asyncio.gather(
                self.api.budget(league),
                self.api.squad(league),
                self.api.market(league),
                self.api.ranking(league),
            )
            stale = (
                self._history_loaded_at is None
                or dt_util.utcnow() - self._history_loaded_at > HISTORY_MAX_AGE
            )
            if stale and not self._history_lock.locked():
                # Takes a while (hundreds of requests) – never block the regular update.
                self.config_entry.async_create_background_task(
                    self.hass, self._background_history(managers), f"{DOMAIN}_history"
                )
            # New market/squad players since the daily load: fetch only those.
            # Without any cache the background load does it (keeps HA startup fast).
            if self._history_loaded_at is not None:
                await self._load_histories(
                    {p.id for p in market} | {p.id for p in squad}, force=False
                )
        except KickbaseAuthError as err:
            raise ConfigEntryAuthFailed("Kickbase-Anmeldung fehlgeschlagen") from err
        except KickbaseError as err:
            raise UpdateFailed(str(err)) from err

        now = dt_util.utcnow()
        # Tabelle (Vereinsnamen + Platz für die Punkteprognose): alle 6 h oder bei neuem Verein.
        tids = {p.team_id for p in (*squad, *market) if p.team_id}
        if not tids <= self._team_names.keys() or self._table_at is None or now - self._table_at > TABLE_MAX_AGE:
            try:
                self._table = await self.api.team_table()
                self._team_names = {tid: name for tid, (name, _) in self._table.items()}
                self._table_at = now
            except KickbaseError as err:
                _LOGGER.debug("Tabelle nicht geladen: %s", err)

        # Spielplan (Anpfiffzeiten) für den Aufstellungs-Wächter – alle paar Stunden reicht.
        if self._matchdays_at is None or now - self._matchdays_at > SCHEDULE_MAX_AGE:
            try:
                self._matchdays = await self.api.matchdays()
                self._matchdays_at = now
            except KickbaseError as err:
                _LOGGER.debug("Spielplan nicht geladen: %s", err)
        lineup = (
            check_lineup(squad, current_matchday(self._matchdays), now) if self._matchdays else None
        )

        my_id = self.api.user_id
        # Snapshot in the event loop – the background load may change the dicts meanwhile.
        plan, profiles = await self.hass.async_add_executor_job(
            self._compute_plan,
            budget,
            squad,
            market,
            managers,
            my_id,
            dict(self._history),
            list(self._transfers),
            self._history_loaded_at,
        )
        forms, forecasts, fixture_day = await self._forecasts(league, squad, market, now)
        upgrades = (
            upgrade_proposals(
                plan=plan, squad=squad, market=market, my_user_id=my_id, forecasts=forecasts, now=now
            )
            if forecasts
            else []
        )
        # Injured/doubtful signals need no history, so they appear right away.
        sells = trend_sales(squad, dict(self._history) if self._history_loaded_at else {}, now)
        radar = league_radar(managers, my_id, await self._rivals(league, managers, my_id, now))
        capital = (
            capital_plan(
                budget=budget,
                squad=squad,
                history=dict(self._history),
                matchdays=self._matchdays,
                bid_limit=plan.bid_limit,
                now=now,
            )
            if self._matchdays
            else None
        )
        return KickbaseData(
            budget=budget,
            squad=squad,
            market=market,
            managers=managers,
            my_user_id=my_id,
            updated=dt_util.utcnow(),
            plan=plan,
            profiles=profiles,
            history_loaded_at=self._history_loaded_at,
            transfer_count=len(self._transfers),
            team_names=dict(self._team_names),
            lineup=lineup,
            forecasts=forecasts,
            forecast_matchday=fixture_day,
            upgrades=upgrades,
            trend_sales=sells,
            radar=radar,
            capital=capital,
            forms=forms,
            finished_matchday=last_finished_matchday(self._matchdays),
        )

    async def _forecasts(
        self, league: str, squad: list[Player], market: list[Player], now: datetime
    ) -> tuple[dict[str, PlayerForm], dict[str, float], int | None]:
        """Expected points for the next matchday that has not started (own squad + market)."""
        upcoming = next(
            (
                d
                for d in sorted(self._matchdays, key=lambda d: d.day)
                if d.matches and all(m.status == 0 and m.kickoff > now for m in d.matches)
            ),
            None,
        )
        try:
            forms = await self.api.lineup_forms(league)
        except KickbaseError as err:
            _LOGGER.debug("Aufstellung (Punkte) nicht geladen: %s", err)
            forms = {}
        # Market players: details (`ap`, `ph`) are missing in the market list – cache 6 h.
        missing = [
            p.id
            for p in market
            if p.id not in self._market_forms or now - self._market_forms[p.id][1] > FORM_MAX_AGE
        ]
        sem = asyncio.Semaphore(PARALLEL)

        async def one(pid: str) -> None:
            async with sem:
                try:
                    self._market_forms[pid] = (await self.api.player_form(league, pid), now)
                except KickbaseError as err:
                    _LOGGER.debug("Spielerdetails %s nicht geladen: %s", pid, err)

        await asyncio.gather(*(one(pid) for pid in missing))
        on_market = {p.id for p in market}
        self._market_forms = {k: v for k, v in self._market_forms.items() if k in on_market}
        if upcoming is None:
            return forms, {}, None
        place = {tid: pl for tid, (_, pl) in self._table.items() if pl}

        def fixture(team_id: str) -> Fixture | None:
            m = upcoming.kickoff_of(team_id)
            if m is None:
                return None
            home = m.home_id == team_id
            return Fixture(m.away_id if home else m.home_id, home)

        forecasts = {p.id: forecast_points(p, forms.get(p.id), fixture(p.team_id), place) for p in squad}
        for p in market:
            form = self._market_forms.get(p.id, (None, None))[0]
            forecasts[p.id] = forecast_points(p, form, fixture(p.team_id), place)
        return forms, forecasts, upcoming.day

    async def _rivals(
        self, league: str, managers: list[Manager], my_id: str, now: datetime
    ) -> dict[str, list[Player]]:
        """Rival squads for the league radar (status of their starters) – hourly."""
        if self._rivals_at is None or now - self._rivals_at > RIVALS_MAX_AGE:
            async def one(uid: str) -> tuple[str, list[Player] | None]:
                try:
                    return uid, await self.api.manager_squad(league, uid)
                except KickbaseError as err:
                    _LOGGER.debug("Kader von %s nicht geladen: %s", uid, err)
                    return uid, None

            results = await asyncio.gather(*(one(m.id) for m in managers if m.id != my_id))
            self._rival_squads.update({uid: sq for uid, sq in results if sq is not None})
            self._rivals_at = now
        return dict(self._rival_squads)

    def _compute_plan(
        self,
        budget: float,
        squad: list[Player],
        market: list[Player],
        managers: list[Manager],
        my_id: str,
        history: dict[str, list[MVPoint]],
        transfers: list[Transfer],
        history_loaded_at: datetime | None,
    ) -> tuple[AutoPlan, list[BidderProfile]]:
        """Runs in the executor (backtest is CPU-heavy)."""
        now = datetime.now(timezone.utc)
        profiles = [BidderProfile.build(m, transfers, history, now) for m in managers]
        rivals = [p for p in profiles if p.id != my_id]
        premium = (
            max((p.expected_overpay for p in rivals), default=AutoRules.default_overpay_pct)
            + AutoRules.bid_margin_pct
        )
        key = (history_loaded_at, round(premium, 2), len(history))
        if self._backtest is None or self._backtest_key != key:
            self._backtest = BacktestResult.run(list(history.values()), premium)
            self._backtest_key = key
        plan = make_plan(
            budget=budget,
            squad=squad,
            market=market,
            my_user_id=my_id,
            transfers=transfers,
            profiles=profiles,
            history=history,
            backtest=self._backtest,
            now=now,
        )
        return plan, profiles
