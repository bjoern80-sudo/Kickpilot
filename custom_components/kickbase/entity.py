"""Shared base entity."""

from __future__ import annotations

from homeassistant.config_entries import ConfigEntry
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import CONF_LEAGUE_NAME, DOMAIN
from .coordinator import KickbaseCoordinator


class KickbaseEntity(CoordinatorEntity[KickbaseCoordinator]):
    _attr_has_entity_name = True

    def __init__(self, coordinator: KickbaseCoordinator, entry: ConfigEntry, key: str) -> None:
        super().__init__(coordinator)
        self._attr_unique_id = f"{entry.unique_id}_{key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=f"Kickbase {entry.data.get(CONF_LEAGUE_NAME, '')}".strip(),
            manufacturer="Kickbase (inoffizielle API)",
            entry_type=DeviceEntryType.SERVICE,
        )
