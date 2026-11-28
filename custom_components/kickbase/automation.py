"""Transfer automation: notifications, confirmation and execution.

* Semi-automatic (default): proposals are sent as a notification with
  "Bestätigen"/"Ablehnen". Only a tap (or the service call) executes them.
* Fully automatic (only after explicit opt-in in the options flow): proposals
  within the limits are executed at the check times, the rest is sent for confirmation.
* Dry run (default on): nothing is sent to Kickbase, only logged.

Every execution re-checks against freshly loaded data first.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
import logging
import secrets
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import Event, HomeAssistant, callback
from homeassistant.helpers.storage import Store
from homeassistant.util import dt as dt_util

from .api import KickbaseError
from .const import (
    DOMAIN,
    MODE_FULL,
    MODE_SEMI,
    OPT_CONFIRM_VALID_HOURS,
    OPT_DRY_RUN,
    OPT_INJURY_WARN,
    OPT_REVIEW,
    OPT_TREND_SALES,
    OPT_UPGRADES,
    OPT_LINEUP_LEAD_HOURS,
    OPT_LINEUP_WARN,
    OPT_FULL_AUTO_ACK,
    OPT_MAX_BID_SUM_PER_DAY,
    OPT_MAX_BIDS_PER_RUN,
    OPT_MAX_SALES_PER_FRIDAY,
    OPT_MODE_BIDS,
    OPT_MODE_SALES,
    OPT_NOTIFY_TARGETS,
    opt,
)
from .coordinator import KickbaseCoordinator
from .insights import matchday_review
from .planner import AutoRules, InjuryAlert, fmt_mio, injured_ids, injury_alerts, next_deadline

_LOGGER = logging.getLogger(__name__)

EVENT_EXECUTED = f"{DOMAIN}_ausgefuehrt"
ACTION_CONFIRM = "KICKBASE_CONFIRM_"
ACTION_REJECT = "KICKBASE_REJECT_"
KIND_BUYS = "kaeufe"
KIND_SALES = "verkaeufe"
KIND_INJURY = "verletzung"  # sale of a newly injured player – ALWAYS needs confirmation
KIND_UPGRADE = "verstaerkung"  # sporting buy (points forecast) – ALWAYS needs confirmation
KIND_TREND = "abwaertstrend"  # sale of a non-core player with falling value – ALWAYS needs confirmation
MAX_ERRORS_IN_A_ROW = 2
WEEKDAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]


def eur(value: float) -> str:
    """12.345.678 € (German format)."""
    sign = "−" if value < 0 else ""
    return f"{sign}{abs(round(value)):,} €".replace(",", ".")


@dataclass
class OrderItem:
    player_id: str
    name: str
    amount: float  # bid, or expected proceeds for a sale
    detail: str = ""  # extra line in the notification


@dataclass
class Order:
    token: str
    kind: str
    items: list[OrderItem]
    created: datetime = field(default_factory=dt_util.utcnow)


class KickbaseAutomation:
    """Holds pending orders and runs confirmed / automatic executions."""

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry, coordinator: KickbaseCoordinator) -> None:
        self.hass = hass
        self.entry = entry
        self.coordinator = coordinator
        self.enabled = True  # switch.…_automatik (restored by the switch entity)
        self._orders: dict[str, Order] = {}
        self._store: Store = Store(hass, 1, f"{DOMAIN}_automation_{entry.entry_id}")
        self._state: dict[str, Any] = {}
        self._alerted_deadline: str | None = None
        self._alerted_lineup: set[str] = set()

    @property
    def options(self) -> dict:
        return self.entry.options

    async def async_load(self) -> None:
        self._state = await self._store.async_load() or {}

    async def _save(self) -> None:
        await self._store.async_save(self._state)

    # ---- entry points ---------------------------------------------------------

    async def async_on_schedule(self, kind: str) -> None:
        """Called at the configured check times (after a fresh refresh)."""
        if not self.enabled:
            _LOGGER.debug("Automatik aus – keine Prüfung (%s)", kind)
            return
        plan = self.coordinator.data.plan if self.coordinator.data else None
        if plan is None:
            return
        if kind == KIND_BUYS:
            await self._send_upgrades()
            items = [OrderItem(b.player.id, b.player.full_name, b.bid) for b in plan.buys]
            mode = opt(self.options, OPT_MODE_BIDS)
        else:
            items = [
                OrderItem(s.player.id, s.player.full_name, s.expected_proceeds) for s in plan.sales
            ]
            mode = opt(self.options, OPT_MODE_SALES)
        if not items:
            return

        if mode == MODE_FULL and opt(self.options, OPT_FULL_AUTO_ACK):
            auto, rest = self._split_by_limits(kind, items)
            if auto:
                await self.async_execute(Order(self._token(), kind, auto), source="Vollautomatik")
            if rest:
                await self.async_send_order(Order(self._token(), kind, rest), note="Über den Grenzen der Vollautomatik.")
        else:
            await self.async_send_order(Order(self._token(), kind, items))

    async def _send_upgrades(self) -> None:
        """Sporting buys at the buy check times – never automatic, always to confirm."""
        data = self.coordinator.data
        if not data or not data.upgrades or not opt(self.options, OPT_UPGRADES):
            return
        items = [
            OrderItem(
                u.player.id,
                u.player.full_name,
                u.bid,
                f"  {u.player.position_name}, erwartet {u.forecast:.0f} Pkt. statt {u.replaces.full_name} "
                f"({u.replaces_forecast:.0f}) – +{u.gain:.0f} Pkt. am {data.forecast_matchday}. Spieltag",
            )
            for u in data.upgrades
        ]
        await self.async_send_order(Order(self._token(), KIND_UPGRADE, items))

    def current_items(self, kind: str) -> list[OrderItem]:
        """Current proposals of one kind as order items (for the services and the card)."""
        data = self.coordinator.data
        plan = data.plan if data else None
        if plan is None:
            return []
        if kind == KIND_BUYS:
            return [OrderItem(b.player.id, b.player.full_name, b.bid) for b in plan.buys]
        if kind == KIND_UPGRADE:
            return [OrderItem(u.player.id, u.player.full_name, u.bid) for u in data.upgrades]
        if kind == KIND_TREND:
            return [OrderItem(t.player.id, t.player.full_name, t.proceeds) for t in data.trend_sales]
        return [OrderItem(s.player.id, s.player.full_name, s.expected_proceeds) for s in plan.sales]

    async def async_send_proposals(self, kind: str) -> str | None:
        """Service kickbase.vorschlaege_senden: send the current proposals for confirmation."""
        await self.coordinator.async_refresh()
        items = self.current_items(kind)
        if not items:
            await self._notify("Kickbase", "Keine Vorschläge dieser Art.")
            return None
        order = Order(self._token(), kind, items)
        await self.async_send_order(order)
        return order.token

    async def async_confirm(self, token: str, source: str) -> list[str]:
        order = self._orders.pop(token, None)
        if order is None:
            msg = "Dieser Vorschlag ist nicht mehr gültig (schon ausgeführt, abgelehnt oder HA neu gestartet)."
            await self._notify("Kickbase", msg)
            return [msg]
        valid = timedelta(hours=opt(self.options, OPT_CONFIRM_VALID_HOURS))
        if dt_util.utcnow() - order.created > valid:
            msg = "Bestätigung abgelaufen. Neue Vorschläge kommen zur nächsten Prüfzeit."
            await self._notify("Kickbase", msg)
            return [msg]
        return await self.async_execute(order, source=source)

    @callback
    def async_reject(self, token: str) -> None:
        if self._orders.pop(token, None):
            _LOGGER.info("Kickbase: Vorschlag %s abgelehnt", token)

    @callback
    def async_handle_action(self, event: Event) -> None:
        """mobile_app_notification_action → confirm / reject."""
        action = str(event.data.get("action", ""))
        if action.startswith(ACTION_CONFIRM):
            token = action.removeprefix(ACTION_CONFIRM)
            if token in self._orders:
                self.entry.async_create_background_task(
                    self.hass, self.async_confirm(token, "Push-Nachricht"), f"{DOMAIN}_confirm"
                )
        elif action.startswith(ACTION_REJECT):
            self.async_reject(action.removeprefix(ACTION_REJECT))

    @callback
    def async_check_deadline(self) -> None:
        """Coordinator listener: warn once per deadline when a balance is needed."""
        if not self.enabled or not self.coordinator.deadline_alert():
            return
        deadline = next_deadline().isoformat()
        if self._alerted_deadline == deadline:
            return
        self._alerted_deadline = deadline
        plan = self.coordinator.data.plan
        items = [OrderItem(s.player.id, s.player.full_name, s.expected_proceeds) for s in plan.sales]
        text = f"Budget nach Geboten {eur(plan.committed_budget)} – bis Freitag 20:30 ausgleichen."
        if items:
            self.entry.async_create_background_task(
                self.hass,
                self.async_send_order(Order(self._token(), KIND_SALES, items), note=text),
                f"{DOMAIN}_deadline",
            )
        else:
            self.entry.async_create_background_task(
                self.hass, self._notify("Kickbase: Ausgleich nötig", text), f"{DOMAIN}_deadline"
            )

    @callback
    def async_check_injuries(self) -> None:
        """Coordinator listener: an own player was newly reported injured → push with sale proposal.

        Never sells on its own – the sale needs a tap on „Verkaufen bestätigen“ (also in full automation).
        """
        data = self.coordinator.data
        if data is None or not data.squad or not self.coordinator.last_update_success:
            return
        current = injured_ids(data.squad)
        if "injured" not in self._state:
            # First run: remember who is injured already, no warning for old injuries.
            self._state["injured"] = sorted(current)
            self.entry.async_create_background_task(self.hass, self._save(), f"{DOMAIN}_injury_init")
            return
        known = set(self._state["injured"])
        alerts = injury_alerts(data.squad, known)
        if current != known:
            # Healed players drop out, so a new injury later warns again.
            self._state["injured"] = sorted(current)
            self.entry.async_create_background_task(self.hass, self._save(), f"{DOMAIN}_injury_save")
        if not alerts or not self.enabled or not opt(self.options, OPT_INJURY_WARN):
            return
        for alert in alerts:
            self.entry.async_create_background_task(
                self.hass, self._send_injury(alert), f"{DOMAIN}_injury_{alert.player.id}"
            )

    async def _send_injury(self, alert: InjuryAlert) -> None:
        p = alert.player
        now = dt_util.now()
        day = "heute" if now.hour < AutoRules.market_value_update_hour else "morgen"
        lines = [f"{p.full_name} ({p.position_name}) ist als verletzt gemeldet."]
        if p.gain_since_purchase is not None:
            lines.append(f"Marktwert {eur(p.market_value)} ({'+' if p.gain_since_purchase >= 0 else ''}{eur(p.gain_since_purchase)} seit Kauf).")
        else:
            lines.append(f"Marktwert {eur(p.market_value)}.")
        lines.append(
            f"Verletzte Spieler verlieren meist an Wert. Bis {day} 22:00 Uhr bringt ein Verkauf an "
            f"Kickbase noch ca. {eur(alert.proceeds)}."
        )
        if alert.in_core:
            lines.append("Achtung: gehört zu deinen Top 11 (Ø-Punkte).")
        if not alert.sellable:
            lines.append(f"Verkauf nicht möglich: {alert.reason}.")
            await self._notify("Kickbase: Spieler verletzt", "\n".join(lines))
            return
        order = Order(self._token(), KIND_INJURY, [OrderItem(p.id, p.full_name, alert.proceeds)])
        self._orders[order.token] = order
        valid = opt(self.options, OPT_CONFIRM_VALID_HOURS)
        if opt(self.options, OPT_DRY_RUN):
            lines.append("Trockenlauf: es wird nichts ausgeführt.")
        lines.append(f"Gültig {valid} h.")
        await self._notify(
            f"Kickbase: {p.full_name} verletzt – verkaufen?",
            "\n".join(lines),
            actions=[
                {"action": ACTION_CONFIRM + order.token, "title": "Verkaufen bestätigen"},
                {"action": ACTION_REJECT + order.token, "title": "Behalten"},
            ],
            token=order.token,
        )

    @callback
    def async_check_trend_sales(self) -> None:
        """Coordinator listener: value of a non-core player keeps falling → sale proposal (once per peak)."""
        data = self.coordinator.data
        if not data or not self.enabled or not opt(self.options, OPT_TREND_SALES):
            return
        alerted = set(self._state.get("trend_alerted", []))
        new = [t for t in data.trend_sales if f"{t.player.id}:{t.peak_date.date()}" not in alerted]
        if not new:
            return
        # Keep only keys of current signals (+ the new ones) so the list stays small.
        current = {f"{t.player.id}:{t.peak_date.date()}" for t in data.trend_sales}
        self._state["trend_alerted"] = sorted(current)
        items = [
            OrderItem(
                t.player.id,
                t.player.full_name,
                t.proceeds,
                f"  {t.player.position_name}, außerhalb deiner Top 11: seit 2 Tagen fallend, "
                f"{t.drop_pct:.1f}".replace(".", ",") + f" % unter dem Hoch von {fmt_mio(t.peak)} ({dt_util.as_local(t.peak_date):%d.%m.}).",
            )
            for t in new
        ]
        order = Order(self._token(), KIND_TREND, items)
        self.entry.async_create_background_task(
            self.hass, self._save_and_send(order), f"{DOMAIN}_trend"
        )

    async def _save_and_send(self, order: Order) -> None:
        await self._save()
        await self.async_send_order(order, note="Vor dem nächsten Update um 22:00 Uhr verkaufen sichert den heutigen Wert.")

    @callback
    def async_check_review(self) -> None:
        """Coordinator listener: push a short review once a matchday is finished."""
        data = self.coordinator.data
        if not data or data.finished_matchday is None or not data.me:
            return
        last = self._state.get("reviewed_day")
        if last is None:
            self._state["reviewed_day"] = data.finished_matchday  # first run: no review for old matchdays
            self.entry.async_create_background_task(self.hass, self._save(), f"{DOMAIN}_review_init")
            return
        if data.finished_matchday <= last:
            return
        self._state["reviewed_day"] = data.finished_matchday
        self.entry.async_create_background_task(self.hass, self._save(), f"{DOMAIN}_review_save")
        if not self.enabled or not opt(self.options, OPT_REVIEW):
            return
        r = matchday_review(
            matchday=data.finished_matchday,
            me=data.me,
            managers=data.managers,
            squad=data.squad,
            forms=data.forms,
            transfers=self.coordinator.transfers,
            my_id=data.my_user_id,
            now=dt_util.utcnow(),
        )
        lines = [
            f"{r.points:.0f} Punkte"
            + (f" – Platz {r.matchday_placement} am Spieltag" if r.matchday_placement else ""),
            f"Gesamt Platz {r.placement}, {r.gap_to_first:.0f} Punkte hinter dem Ersten."
            if r.gap_to_first > 0
            else f"Gesamt Platz {r.placement} – du führst!",
        ]
        if r.best_points > r.points:
            lines.append(
                f"Beste mögliche Startelf ({r.best_formation}): {r.best_points:.0f} Punkte "
                f"(+{r.best_points - r.points:.0f})."
                + (f" Auf der Bank: {', '.join(r.missed)}." if r.missed else "")
            )
        if r.buys:
            total = sum(g for _, g in r.buys)
            lines.append(
                f"Käufe der letzten 7 Tage: {len(r.buys)}, Marktwert seit Kauf {'+' if total >= 0 else ''}{eur(total)}."
            )
        self.entry.async_create_background_task(
            self.hass,
            self._notify(f"Kickbase: Rückblick {r.matchday}. Spieltag", "\n".join(lines)),
            f"{DOMAIN}_review",
        )

    @callback
    def async_check_lineup(self) -> None:
        """Coordinator listener: warn before kick-off if the starting eleven has problems.

        Read-only – the lineup is never changed. Each problem is reported once, within
        `lineup_lead_hours` before the first kick-off of the matchday (lineup locks then).
        """
        data = self.coordinator.data
        check = data.lineup if data else None
        if not self.enabled or not opt(self.options, OPT_LINEUP_WARN) or check is None:
            return
        now = dt_util.utcnow()
        due = check.due(now, float(opt(self.options, OPT_LINEUP_LEAD_HOURS)))
        new = [i for i in due if i.is_problem and i.key not in self._alerted_lineup]
        if not new:
            return
        self._alerted_lineup |= {i.key for i in due}
        # Forget old keys (deadlines in the past) so the set does not grow forever.
        self._alerted_lineup = {
            k for k in self._alerted_lineup
            if any(i.key == k for i in check.issues)
        }
        lines = []
        for i in new:
            line = i.text
            if i.kind != "unvollstaendig":
                line += (
                    f" → Ersatz: {i.replacement.full_name} (Ø {i.replacement.average_points:.0f})"
                    if i.replacement
                    else " → kein fitter Ersatz auf dieser Position"
                )
            lines.append(line)
        tips = [i for i in due if not i.is_problem]
        if tips:
            lines.append("Tipp: " + "; ".join(t.text for t in tips))
        first = min(i.deadline for i in new if i.deadline)
        local = dt_util.as_local(first)
        lines.append(
            f"Erster Anpfiff {WEEKDAYS[local.weekday()]} {local:%H:%M} Uhr – bis dahin muss die Aufstellung "
            "stehen, sie gilt dann für den ganzen Spieltag."
        )
        lines.append("Aufstellung bitte in der Kickbase-App ändern.")
        self.entry.async_create_background_task(
            self.hass,
            self._notify(f"Kickbase: Aufstellung prüfen (Spieltag {check.matchday})", "\n".join(lines)),
            f"{DOMAIN}_lineup",
        )

    # ---- notifications ---------------------------------------------------------

    async def async_send_order(self, order: Order, note: str | None = None) -> None:
        self._orders[order.token] = order
        total = sum(i.amount for i in order.items)
        valid = opt(self.options, OPT_CONFIRM_VALID_HOURS)
        if order.kind in (KIND_BUYS, KIND_UPGRADE):
            n = len(order.items)
            title = (
                f"Kickbase: {n} Gebot{'e' if n != 1 else ''} vorgeschlagen"
                if order.kind == KIND_BUYS
                else f"Kickbase: {n} Verstärkung{'en' if n != 1 else ''} für die Startelf"
            )
            lines = []
            for i in order.items:
                lines.append(f"{i.name}: {eur(i.amount)}")
                if i.detail:
                    lines.append(i.detail)
            lines.append(f"Zusammen {eur(total)}")
            confirm = "Gebote bestätigen"
        elif order.kind == KIND_TREND:
            title = "Kickbase: Marktwert fällt – verkaufen?"
            lines = []
            for i in order.items:
                lines.append(f"{i.name}: ca. {eur(i.amount)}")
                if i.detail:
                    lines.append(i.detail)
            confirm = "Verkaufen bestätigen"
        else:
            title = f"Kickbase: {len(order.items)} Verkauf{'e' if len(order.items) != 1 else ''} vorgeschlagen"
            lines = [f"{i.name}: ca. {eur(i.amount)}" for i in order.items]
            lines.append(f"Erlös zusammen ca. {eur(total)}")
            confirm = "Verkäufe bestätigen"
        if note:
            lines.insert(0, note)
        if opt(self.options, OPT_DRY_RUN):
            lines.append("Trockenlauf: es wird nichts ausgeführt.")
        lines.append(f"Gültig {valid} h.")
        await self._notify(
            title,
            "\n".join(lines),
            actions=[
                {"action": ACTION_CONFIRM + order.token, "title": confirm},
                {"action": ACTION_REJECT + order.token, "title": "Ablehnen"},
            ],
            token=order.token,
        )

    async def _notify(
        self,
        title: str,
        message: str,
        actions: list[dict] | None = None,
        token: str | None = None,
    ) -> None:
        targets: list[str] = opt(self.options, OPT_NOTIFY_TARGETS) or []
        sent = False
        for target in targets:
            domain, _, service = target.partition(".")
            if domain != "notify" or not self.hass.services.has_service("notify", service):
                _LOGGER.warning("Benachrichtigungsziel %s gibt es nicht", target)
                continue
            data: dict[str, Any] = {"title": title, "message": message}
            if actions and service.startswith("mobile_app_"):
                data["data"] = {"actions": actions, "tag": f"kickbase_{token or 'info'}"}
            try:
                await self.hass.services.async_call("notify", service, data, blocking=True)
                sent = True
            except Exception as err:  # noqa: BLE001 – a broken target must not stop the rest
                _LOGGER.warning("Benachrichtigung an %s fehlgeschlagen: %s", target, err)
        if not sent:
            # Fallback: notification in the HA UI (confirm via the service there).
            hint = (
                f"\n\nBestätigen: Aktion kickbase.vorschlaege_ausfuehren mit auftrag: {token}"
                if token
                else ""
            )
            await self.hass.services.async_call(
                "persistent_notification",
                "create",
                {"title": title, "message": message + hint, "notification_id": f"kickbase_{token or 'info'}"},
                blocking=True,
            )

    # ---- execution -------------------------------------------------------------

    def _split_by_limits(self, kind: str, items: list[OrderItem]) -> tuple[list[OrderItem], list[OrderItem]]:
        today = dt_util.now().date().isoformat()
        if kind == KIND_BUYS:
            max_count = opt(self.options, OPT_MAX_BIDS_PER_RUN)
            spent = self._state.get("bid_sum", 0.0) if self._state.get("bid_day") == today else 0.0
            budget = opt(self.options, OPT_MAX_BID_SUM_PER_DAY) - spent
            auto: list[OrderItem] = []
            rest: list[OrderItem] = []
            for item in items:
                if len(auto) < max_count and item.amount <= budget:
                    auto.append(item)
                    budget -= item.amount
                else:
                    rest.append(item)
            return auto, rest
        deadline = next_deadline().date().isoformat()
        sold = self._state.get("sales_count", 0) if self._state.get("sales_week") == deadline else 0
        free = max(0, opt(self.options, OPT_MAX_SALES_PER_FRIDAY) - sold)
        return items[:free], items[free:]

    async def async_execute(self, order: Order, source: str) -> list[str]:
        """Re-check against fresh data, then execute (or log in dry run)."""
        if not self.enabled:
            msg = "Automatik ist ausgeschaltet – nichts ausgeführt."
            await self._notify("Kickbase", msg)
            return [msg]
        dry = bool(opt(self.options, OPT_DRY_RUN))
        await self.coordinator.async_refresh()
        data = self.coordinator.data
        plan = data.plan if data else None
        if plan is None or not self.coordinator.last_update_success:
            msg = "Kickbase-Daten konnten nicht geladen werden – nichts ausgeführt."
            await self._notify("Kickbase", msg)
            return [msg]

        api = self.coordinator.api
        league = self.coordinator.league_id
        log: list[str] = []
        errors = 0
        done_amount = 0.0
        done_count = 0
        prefix = "Trockenlauf – würde " if dry else ""

        if order.kind == KIND_BUYS:
            current = {b.player.id: b for b in plan.buys}
            for item in order.items:
                proposal = current.get(item.player_id)
                if proposal is None:
                    log.append(f"– {item.name}: nicht mehr vorgeschlagen, übersprungen")
                    continue
                if proposal.bid > item.amount:
                    log.append(
                        f"– {item.name}: Gebot müsste jetzt {eur(proposal.bid)} sein, übersprungen"
                    )
                    continue
                if dry:
                    log.append(f"✓ {prefix}{eur(item.amount)} für {item.name} bieten")
                    continue
                try:
                    await api.place_offer(league, item.player_id, int(round(item.amount)))
                except KickbaseError as err:
                    errors += 1
                    log.append(f"✗ {item.name}: {err}")
                else:
                    done_amount += item.amount
                    done_count += 1
                    log.append(f"✓ Gebot {eur(item.amount)} für {item.name}")
        elif order.kind == KIND_UPGRADE:
            current_up = {u.player.id: u for u in data.upgrades}
            for item in order.items:
                proposal = current_up.get(item.player_id)
                if proposal is None:
                    log.append(f"– {item.name}: nicht mehr vorgeschlagen, übersprungen")
                    continue
                if proposal.bid > item.amount:
                    log.append(f"– {item.name}: Gebot müsste jetzt {eur(proposal.bid)} sein, übersprungen")
                    continue
                if dry:
                    log.append(f"✓ {prefix}{eur(item.amount)} für {item.name} bieten")
                    continue
                try:
                    await api.place_offer(league, item.player_id, int(round(item.amount)))
                except KickbaseError as err:
                    errors += 1
                    log.append(f"✗ {item.name}: {err}")
                else:
                    done_amount += item.amount
                    done_count += 1
                    log.append(f"✓ Gebot {eur(item.amount)} für {item.name}")
        elif order.kind in (KIND_INJURY, KIND_TREND):
            squad = {p.id: p for p in data.squad}
            for item in order.items:
                player = squad.get(item.player_id)
                if player is None:
                    log.append(f"– {item.name}: nicht mehr im Kader, übersprungen")
                    continue
                if order.kind == KIND_INJURY:
                    check = injury_alerts(data.squad, set())
                    alert = next((a for a in check if a.player.id == item.player_id), None)
                    if alert is None:
                        log.append(f"– {item.name}: nicht mehr als verletzt gemeldet, übersprungen")
                        continue
                    if not alert.sellable:
                        log.append(f"– {item.name}: {alert.reason}, übersprungen")
                        continue
                elif not any(t.player.id == item.player_id for t in data.trend_sales):
                    log.append(f"– {item.name}: Marktwert fällt nicht mehr bzw. Verkauf nicht mehr möglich, übersprungen")
                    continue
                if dry:
                    log.append(f"✓ {prefix}{item.name} für ca. {eur(player.market_value)} an Kickbase verkaufen")
                    continue
                try:
                    if not player.on_market:
                        await api.list_for_sale(league, item.player_id, int(round(player.market_value)))
                    await api.sell_to_kickbase(league, item.player_id)
                except KickbaseError as err:
                    errors += 1
                    log.append(f"✗ {item.name}: {err}")
                else:
                    done_count += 1
                    log.append(f"✓ {item.name} an Kickbase verkauft")
        else:
            current_sales = {s.player.id: s for s in plan.sales}
            squad = {p.id: p for p in data.squad}
            for item in order.items:
                player = squad.get(item.player_id)
                if player is None:
                    log.append(f"– {item.name}: nicht mehr im Kader, übersprungen")
                    continue
                if item.player_id not in current_sales:
                    log.append(f"– {item.name}: Verkauf nicht mehr nötig, übersprungen")
                    continue
                if dry:
                    log.append(f"✓ {prefix}{item.name} für ca. {eur(player.market_value)} an Kickbase verkaufen")
                    continue
                try:
                    if not player.on_market:
                        await api.list_for_sale(league, item.player_id, int(round(player.market_value)))
                    await api.sell_to_kickbase(league, item.player_id)
                except KickbaseError as err:
                    errors += 1
                    log.append(f"✗ {item.name}: {err}")
                else:
                    done_count += 1
                    log.append(f"✓ {item.name} an Kickbase verkauft")

        if not dry and order.kind in (KIND_BUYS, KIND_UPGRADE):
            await self._book(KIND_BUYS, done_count, done_amount)
        elif not dry and order.kind == KIND_SALES:  # single sales do not count against Friday limits
            await self._book(order.kind, done_count, done_amount)
        await self._track_errors(errors, source)

        title = f"Kickbase: {'Gebote' if order.kind in (KIND_BUYS, KIND_UPGRADE) else 'Verkäufe'} ({source})"
        if dry:
            title += " – Trockenlauf"
        await self._notify(title, "\n".join(log) or "Nichts zu tun.")
        self.hass.bus.async_fire(
            EVENT_EXECUTED,
            {"art": order.kind, "quelle": source, "trockenlauf": dry, "protokoll": log},
        )
        if self.hass.services.has_service("logbook", "log"):
            await self.hass.services.async_call(
                "logbook",
                "log",
                {"name": "Kickbase", "message": f"{title}: {'; '.join(log)}", "domain": DOMAIN},
            )
        _LOGGER.info("%s: %s", title, "; ".join(log))
        if not dry and done_count:
            await self.coordinator.async_request_refresh()
        return log

    async def _book(self, kind: str, count: int, amount: float) -> None:
        if not count:
            return
        if kind == KIND_BUYS:
            today = dt_util.now().date().isoformat()
            if self._state.get("bid_day") != today:
                self._state["bid_day"], self._state["bid_sum"] = today, 0.0
            self._state["bid_sum"] = self._state.get("bid_sum", 0.0) + amount
        else:
            week = next_deadline().date().isoformat()
            if self._state.get("sales_week") != week:
                self._state["sales_week"], self._state["sales_count"] = week, 0
            self._state["sales_count"] = self._state.get("sales_count", 0) + count
        await self._save()

    async def _track_errors(self, errors: int, source: str) -> None:
        if errors == 0:
            if self._state.get("errors_in_a_row"):
                self._state["errors_in_a_row"] = 0
                await self._save()
            return
        self._state["errors_in_a_row"] = self._state.get("errors_in_a_row", 0) + 1
        await self._save()
        if self._state["errors_in_a_row"] < MAX_ERRORS_IN_A_ROW:
            return
        full = MODE_FULL in (opt(self.options, OPT_MODE_BIDS), opt(self.options, OPT_MODE_SALES))
        if full:
            self._state["errors_in_a_row"] = 0
            await self._save()
            self.hass.config_entries.async_update_entry(
                self.entry,
                options={**self.options, OPT_MODE_BIDS: MODE_SEMI, OPT_MODE_SALES: MODE_SEMI},
            )
            await self._notify(
                "Kickbase: Vollautomatik abgeschaltet",
                f"{MAX_ERRORS_IN_A_ROW} Ausführungen in Folge mit Fehlern. "
                "Betriebsart steht wieder auf halbautomatisch.",
            )

    @staticmethod
    def _token() -> str:
        return secrets.token_hex(4)
