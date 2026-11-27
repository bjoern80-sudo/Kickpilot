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
from .planner import next_deadline

_LOGGER = logging.getLogger(__name__)

EVENT_EXECUTED = f"{DOMAIN}_ausgefuehrt"
ACTION_CONFIRM = "KICKBASE_CONFIRM_"
ACTION_REJECT = "KICKBASE_REJECT_"
KIND_BUYS = "kaeufe"
KIND_SALES = "verkaeufe"
MAX_ERRORS_IN_A_ROW = 2


def eur(value: float) -> str:
    """12.345.678 € (German format)."""
    sign = "−" if value < 0 else ""
    return f"{sign}{abs(round(value)):,} €".replace(",", ".")


@dataclass
class OrderItem:
    player_id: str
    name: str
    amount: float  # bid, or expected proceeds for a sale


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

    async def async_send_proposals(self, kind: str) -> str | None:
        """Service kickbase.vorschlaege_senden: send the current proposals for confirmation."""
        await self.coordinator.async_refresh()
        plan = self.coordinator.data.plan if self.coordinator.data else None
        if plan is None:
            return None
        if kind == KIND_BUYS:
            items = [OrderItem(b.player.id, b.player.full_name, b.bid) for b in plan.buys]
        else:
            items = [OrderItem(s.player.id, s.player.full_name, s.expected_proceeds) for s in plan.sales]
        if not items:
            await self._notify("Kickbase", f"Keine {'Kauf' if kind == KIND_BUYS else 'Verkaufs'}vorschläge.")
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

    # ---- notifications ---------------------------------------------------------

    async def async_send_order(self, order: Order, note: str | None = None) -> None:
        self._orders[order.token] = order
        total = sum(i.amount for i in order.items)
        valid = opt(self.options, OPT_CONFIRM_VALID_HOURS)
        if order.kind == KIND_BUYS:
            title = f"Kickbase: {len(order.items)} Gebot{'e' if len(order.items) != 1 else ''} vorgeschlagen"
            lines = [f"{i.name}: {eur(i.amount)}" for i in order.items]
            lines.append(f"Zusammen {eur(total)}")
            confirm = "Gebote bestätigen"
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

        if not dry:
            await self._book(order.kind, done_count, done_amount)
        await self._track_errors(errors, source)

        title = f"Kickbase: {'Gebote' if order.kind == KIND_BUYS else 'Verkäufe'} ({source})"
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
