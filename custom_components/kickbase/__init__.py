"""Kickbase integration for Home Assistant."""

from __future__ import annotations

import aiohttp
import voluptuous as vol

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_EMAIL, CONF_PASSWORD, Platform
from homeassistant.core import HomeAssistant, ServiceCall, ServiceResponse, SupportsResponse
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.aiohttp_client import async_create_clientsession

from .api import KickbaseApi
from .automation import KIND_BUYS, KIND_SALES, KickbaseAutomation, Order, OrderItem
from .const import DOMAIN
from .coordinator import KickbaseCoordinator

PLATFORMS: list[Platform] = [Platform.BINARY_SENSOR, Platform.SELECT, Platform.SENSOR, Platform.SWITCH]

SERVICE_REFRESH_PLAN = "plan_aktualisieren"
SERVICE_SEND = "vorschlaege_senden"
SERVICE_EXECUTE = "vorschlaege_ausfuehren"

KIND = vol.In([KIND_BUYS, KIND_SALES])

type KickbaseConfigEntry = ConfigEntry[KickbaseCoordinator]


async def async_setup_entry(hass: HomeAssistant, entry: KickbaseConfigEntry) -> bool:
    """Set up Kickbase from a config entry."""
    # Own session without cookie jar: the auth token is sent explicitly per request.
    session = async_create_clientsession(hass, cookie_jar=aiohttp.DummyCookieJar())
    api = KickbaseApi(session, entry.data[CONF_EMAIL], entry.data[CONF_PASSWORD])
    coordinator = KickbaseCoordinator(hass, entry, api)
    await coordinator.async_load_cache()
    await coordinator.async_config_entry_first_refresh()
    entry.runtime_data = coordinator

    automation = KickbaseAutomation(hass, entry, coordinator)
    await automation.async_load()
    coordinator.automation = automation
    coordinator.on_schedule = automation.async_on_schedule
    coordinator.async_setup_schedule()
    entry.async_on_unload(coordinator.async_cancel_schedule)
    entry.async_on_unload(coordinator.async_add_listener(automation.async_check_deadline))
    entry.async_on_unload(
        hass.bus.async_listen("mobile_app_notification_action", automation.async_handle_action)
    )

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    # Options changed (interval, times, …) → reload so they apply immediately.
    entry.async_on_unload(entry.add_update_listener(_async_options_updated))
    _register_services(hass)
    return True


def _automations(hass: HomeAssistant) -> list[KickbaseAutomation]:
    return [
        e.runtime_data.automation
        for e in hass.config_entries.async_loaded_entries(DOMAIN)
        if getattr(e.runtime_data, "automation", None)
    ]


def _register_services(hass: HomeAssistant) -> None:
    if hass.services.has_service(DOMAIN, SERVICE_REFRESH_PLAN):
        return

    async def _refresh_plan(call: ServiceCall) -> None:
        """Reload transfers + histories and recompute the plan (read-only)."""
        for e in hass.config_entries.async_loaded_entries(DOMAIN):
            c: KickbaseCoordinator = e.runtime_data
            if c.data:
                await c.async_refresh_history(c.data.managers)
            await c.async_refresh()

    async def _send(call: ServiceCall) -> ServiceResponse:
        tokens = [await a.async_send_proposals(call.data["art"]) for a in _automations(hass)]
        return {"auftraege": [t for t in tokens if t]}

    async def _execute(call: ServiceCall) -> ServiceResponse:
        """REAL transactions unless dry run is on. Needs an order token or a kind."""
        token = call.data.get("auftrag")
        kind = call.data.get("art")
        if not token and not kind:
            raise ServiceValidationError("auftrag oder art angeben")
        logs: list[str] = []
        for a in _automations(hass):
            if token:
                if token in a._orders:  # noqa: SLF001
                    logs += await a.async_confirm(token, "Aktion")
                continue
            plan = a.coordinator.data.plan if a.coordinator.data else None
            if plan is None:
                continue
            if kind == KIND_BUYS:
                items = [OrderItem(b.player.id, b.player.full_name, b.bid) for b in plan.buys]
            else:
                items = [OrderItem(s.player.id, s.player.full_name, s.expected_proceeds) for s in plan.sales]
            if items:
                logs += await a.async_execute(Order(a._token(), kind, items), source="Aktion")  # noqa: SLF001
        if token and not logs:
            raise ServiceValidationError(f"Auftrag {token} ist nicht (mehr) gültig")
        return {"protokoll": logs}

    hass.services.async_register(DOMAIN, SERVICE_REFRESH_PLAN, _refresh_plan)
    hass.services.async_register(
        DOMAIN,
        SERVICE_SEND,
        _send,
        schema=vol.Schema({vol.Required("art"): KIND}),
        supports_response=SupportsResponse.OPTIONAL,
    )
    hass.services.async_register(
        DOMAIN,
        SERVICE_EXECUTE,
        _execute,
        schema=vol.Schema({vol.Optional("auftrag"): cv.string, vol.Optional("art"): KIND}),
        supports_response=SupportsResponse.OPTIONAL,
    )


async def _async_options_updated(hass: HomeAssistant, entry: KickbaseConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: KickbaseConfigEntry) -> bool:
    """Unload a config entry."""
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded and len(hass.config_entries.async_loaded_entries(DOMAIN)) <= 1:
        for service in (SERVICE_REFRESH_PLAN, SERVICE_SEND, SERVICE_EXECUTE):
            hass.services.async_remove(DOMAIN, service)
    return unloaded
