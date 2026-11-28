"""Binary sensors: Friday balance needed, lineup problem before kick-off."""

from __future__ import annotations

from typing import Any

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import KickbaseConfigEntry
from .entity import KickbaseEntity
from .lineup import LineupIssue


async def async_setup_entry(
    hass: HomeAssistant,
    entry: KickbaseConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    c = entry.runtime_data
    async_add_entities(
        [BalanceNeededSensor(c, entry, "balance_needed"), LineupProblemSensor(c, entry, "lineup_problem")]
    )


class BalanceNeededSensor(KickbaseEntity, BinarySensorEntity):
    _attr_translation_key = "balance_needed"
    _attr_device_class = BinarySensorDeviceClass.PROBLEM

    @property
    def is_on(self) -> bool:
        return self.coordinator.deadline_alert()


def _issue(i: LineupIssue) -> dict[str, Any]:
    return {
        "art": i.kind,
        "text": i.text,
        "spieler": i.player.full_name if i.player else None,
        "spieler_id": i.player.id if i.player else None,
        "ersatz": i.replacement.full_name if i.replacement else None,
        "ersatz_schnitt": round(i.replacement.average_points) if i.replacement else None,
        "bis": i.deadline.isoformat() if i.deadline else None,
    }


class LineupProblemSensor(KickbaseEntity, BinarySensorEntity):
    """On while the starting eleven has a problem that can still be fixed."""

    _attr_translation_key = "lineup_problem"
    _attr_device_class = BinarySensorDeviceClass.PROBLEM

    @property
    def _check(self):
        data = self.coordinator.data
        return data.lineup if data else None

    @property
    def available(self) -> bool:
        return super().available and self._check is not None

    @property
    def is_on(self) -> bool:
        return bool(self._check and self._check.problems)

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        c = self._check
        if c is None:
            return {}
        return {
            "spieltag": c.matchday,
            "naechster_anpfiff": c.next_kickoff.isoformat() if c.next_kickoff else None,
            "startelf": c.starters,
            "noch_aenderbar": c.open_players,
            "probleme": [_issue(i) for i in c.problems],
            "tipps": [_issue(i) for i in c.tips],
        }
