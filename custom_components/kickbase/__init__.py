"""Kickbase integration for Home Assistant."""

from __future__ import annotations

import aiohttp

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_EMAIL, CONF_PASSWORD, Platform
from homeassistant.core import HomeAssistant, ServiceCall
from homeassistant.helpers.aiohttp_client import async_create_clientsession

from .api import KickbaseApi
from .const import DOMAIN
from .coordinator import KickbaseCoordinator

PLATFORMS: list[Platform] = [Platform.BINARY_SENSOR, Platform.SENSOR]

SERVICE_REFRESH_PLAN = "plan_aktualisieren"

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

    coordinator.async_setup_schedule()
    entry.async_on_unload(coordinator.async_cancel_schedule)

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    # Options changed (interval, times, …) → reload so they apply immediately.
    entry.async_on_unload(entry.add_update_listener(_async_options_updated))

    if not hass.services.has_service(DOMAIN, SERVICE_REFRESH_PLAN):

        async def _refresh_plan(call: ServiceCall) -> None:
            """Reload transfers + histories and recompute the plan (read-only)."""
            for e in hass.config_entries.async_loaded_entries(DOMAIN):
                c: KickbaseCoordinator = e.runtime_data
                if c.data:
                    await c.async_refresh_history(c.data.managers)
                await c.async_refresh()

        hass.services.async_register(DOMAIN, SERVICE_REFRESH_PLAN, _refresh_plan)
    return True


async def _async_options_updated(hass: HomeAssistant, entry: KickbaseConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: KickbaseConfigEntry) -> bool:
    """Unload a config entry."""
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded and len(hass.config_entries.async_loaded_entries(DOMAIN)) <= 1:
        hass.services.async_remove(DOMAIN, SERVICE_REFRESH_PLAN)
    return unloaded
