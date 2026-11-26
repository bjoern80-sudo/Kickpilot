"""Selects: mode for bids and sales (semi / full). Writes the entry options."""

from __future__ import annotations

from homeassistant.components.select import SelectEntity
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import KickbaseConfigEntry
from .const import MODE_FULL, MODE_SEMI, OPT_FULL_AUTO_ACK, OPT_MODE_BIDS, OPT_MODE_SALES, opt
from .entity import KickbaseEntity


async def async_setup_entry(
    hass: HomeAssistant,
    entry: KickbaseConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    c = entry.runtime_data
    async_add_entities(
        [
            ModeSelect(c, entry, "mode_bids", OPT_MODE_BIDS),
            ModeSelect(c, entry, "mode_sales", OPT_MODE_SALES),
        ]
    )


class ModeSelect(KickbaseEntity, SelectEntity):
    _attr_options = [MODE_SEMI, MODE_FULL]

    def __init__(self, coordinator, entry: KickbaseConfigEntry, key: str, option: str) -> None:
        super().__init__(coordinator, entry, key)
        self._entry = entry
        self._option = option
        self._attr_translation_key = key

    @property
    def current_option(self) -> str:
        return opt(self._entry.options, self._option)

    async def async_select_option(self, option: str) -> None:
        if option == MODE_FULL and not opt(self._entry.options, OPT_FULL_AUTO_ACK):
            raise ServiceValidationError(
                "Vollautomatik zuerst in den Einstellungen der Integration bestätigen "
                "(Häkchen „echte Transaktionen ohne Rückfrage“)."
            )
        # Triggers the update listener → reload with the new mode.
        self.hass.config_entries.async_update_entry(
            self._entry, options={**self._entry.options, self._option: option}
        )
