"""Switch: automation on/off (emergency stop). Restored after restart."""

from __future__ import annotations

from typing import Any

from homeassistant.components.switch import SwitchEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback
from homeassistant.helpers.restore_state import RestoreEntity

from . import KickbaseConfigEntry
from .const import OPT_DESIGN, OPT_DRY_RUN, opt
from .entity import KickbaseEntity


async def async_setup_entry(
    hass: HomeAssistant,
    entry: KickbaseConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    async_add_entities([AutomationSwitch(entry.runtime_data, entry, "automation")])


class AutomationSwitch(KickbaseEntity, SwitchEntity, RestoreEntity):
    _attr_translation_key = "automation"

    async def async_added_to_hass(self) -> None:
        await super().async_added_to_hass()
        last = await self.async_get_last_state()
        if last is not None and last.state in ("on", "off"):
            self.coordinator.automation.enabled = last.state == "on"

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        """Read by the Kickpilot card (design and dry-run badge)."""
        options = self.coordinator.config_entry.options
        return {"design": opt(options, OPT_DESIGN), "trockenlauf": bool(opt(options, OPT_DRY_RUN))}

    @property
    def is_on(self) -> bool:
        return self.coordinator.automation.enabled

    async def async_turn_on(self, **kwargs: Any) -> None:
        self.coordinator.automation.enabled = True
        self.async_write_ha_state()

    async def async_turn_off(self, **kwargs: Any) -> None:
        self.coordinator.automation.enabled = False
        self.async_write_ha_state()
