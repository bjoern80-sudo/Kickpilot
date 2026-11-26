"""Binary sensor: Friday balance needed (budget after bids < 0 and deadline close)."""

from __future__ import annotations

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import KickbaseConfigEntry
from .entity import KickbaseEntity


async def async_setup_entry(
    hass: HomeAssistant,
    entry: KickbaseConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    async_add_entities([BalanceNeededSensor(entry.runtime_data, entry, "balance_needed")])


class BalanceNeededSensor(KickbaseEntity, BinarySensorEntity):
    _attr_translation_key = "balance_needed"
    _attr_device_class = BinarySensorDeviceClass.PROBLEM

    @property
    def is_on(self) -> bool:
        return self.coordinator.deadline_alert()
