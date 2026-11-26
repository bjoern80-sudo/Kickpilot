"""Kickbase integration for Home Assistant."""

from __future__ import annotations

import aiohttp

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_EMAIL, CONF_PASSWORD, Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_create_clientsession

from .api import KickbaseApi
from .coordinator import KickbaseCoordinator

PLATFORMS: list[Platform] = [Platform.SENSOR]

type KickbaseConfigEntry = ConfigEntry[KickbaseCoordinator]


async def async_setup_entry(hass: HomeAssistant, entry: KickbaseConfigEntry) -> bool:
    """Set up Kickbase from a config entry."""
    # Own session without cookie jar: the auth token is sent explicitly per request.
    session = async_create_clientsession(hass, cookie_jar=aiohttp.DummyCookieJar())
    api = KickbaseApi(session, entry.data[CONF_EMAIL], entry.data[CONF_PASSWORD])
    coordinator = KickbaseCoordinator(hass, entry, api)
    await coordinator.async_config_entry_first_refresh()
    entry.runtime_data = coordinator

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    # Options changed (interval, times, …) → reload so they apply immediately.
    entry.async_on_unload(entry.add_update_listener(_async_options_updated))
    return True


async def _async_options_updated(hass: HomeAssistant, entry: KickbaseConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: KickbaseConfigEntry) -> bool:
    """Unload a config entry."""
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
