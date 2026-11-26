"""Kickbase sensors: budget, team value, open bids, deadline, placement, squad."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
    SensorStateClass,
)
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from . import KickbaseConfigEntry
from .const import CONF_LEAGUE_NAME, DOMAIN, MAX_DEBT_SHARE_OF_TEAM_VALUE
from .coordinator import KickbaseCoordinator, KickbaseData, next_deadline


def _open_bids_before_deadline(d: KickbaseData) -> float:
    deadline = next_deadline()
    return sum(
        p.my_offer_price or 0
        for p in d.market
        if p.my_offer_price and (p.expires_at is None or p.expires_at <= deadline)
    )


def _all_open_bids(d: KickbaseData) -> float:
    return sum(p.my_offer_price or 0 for p in d.market)


def _squad_attrs(d: KickbaseData) -> dict[str, Any]:
    players = sorted(d.squad, key=lambda p: -p.average_points)
    return {
        "spieler": [
            {
                "id": p.id,
                "name": p.full_name,
                "position": p.position_name,
                "marktwert": round(p.market_value),
                "trend_24h": round(p.trend_24h),
                "punkte": round(p.total_points),
                "schnitt": round(p.average_points, 1),
                "fit": p.is_fit,
                "auf_transfermarkt": p.on_market,
            }
            for p in players
        ]
    }


def _bid_attrs(d: KickbaseData) -> dict[str, Any]:
    return {
        "gebote": [
            {
                "id": p.id,
                "name": p.full_name,
                "gebot": round(p.my_offer_price or 0),
                "marktwert": round(p.market_value),
                "endet": p.expires_at.isoformat() if p.expires_at else None,
            }
            for p in d.market
            if p.my_offer_price
        ]
    }


@dataclass(frozen=True, kw_only=True)
class KickbaseSensorDescription(SensorEntityDescription):
    value_fn: Callable[[KickbaseData], float | int | datetime | None]
    attrs_fn: Callable[[KickbaseData], dict[str, Any]] | None = None


EURO = {
    "device_class": SensorDeviceClass.MONETARY,
    "native_unit_of_measurement": "EUR",
    "state_class": SensorStateClass.TOTAL,
    "suggested_display_precision": 0,
}

SENSORS: tuple[KickbaseSensorDescription, ...] = (
    KickbaseSensorDescription(key="budget", translation_key="budget", value_fn=lambda d: d.budget, **EURO),
    KickbaseSensorDescription(
        key="team_value", translation_key="team_value", value_fn=lambda d: d.team_value, **EURO
    ),
    KickbaseSensorDescription(
        key="budget_after_bids",
        translation_key="budget_after_bids",
        value_fn=lambda d: d.budget - _open_bids_before_deadline(d),
        **EURO,
    ),
    KickbaseSensorDescription(
        key="open_bids",
        translation_key="open_bids",
        value_fn=_all_open_bids,
        attrs_fn=_bid_attrs,
        **EURO,
    ),
    KickbaseSensorDescription(
        key="debt_limit",
        translation_key="debt_limit",
        value_fn=lambda d: -MAX_DEBT_SHARE_OF_TEAM_VALUE * d.team_value,
        **EURO,
    ),
    KickbaseSensorDescription(
        key="next_deadline",
        translation_key="next_deadline",
        device_class=SensorDeviceClass.TIMESTAMP,
        value_fn=lambda d: next_deadline(),
    ),
    KickbaseSensorDescription(
        key="placement",
        translation_key="placement",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda d: d.me.placement if d.me else None,
        attrs_fn=lambda d: {
            "punkte": round(d.me.season_points) if d.me else None,
            "manager": len(d.managers),
        },
    ),
    KickbaseSensorDescription(
        key="squad_size",
        translation_key="squad_size",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda d: len(d.squad),
        attrs_fn=_squad_attrs,
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: KickbaseConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    coordinator = entry.runtime_data
    async_add_entities(KickbaseSensor(coordinator, entry, desc) for desc in SENSORS)


class KickbaseSensor(CoordinatorEntity[KickbaseCoordinator], SensorEntity):
    _attr_has_entity_name = True
    entity_description: KickbaseSensorDescription

    def __init__(
        self,
        coordinator: KickbaseCoordinator,
        entry: KickbaseConfigEntry,
        description: KickbaseSensorDescription,
    ) -> None:
        super().__init__(coordinator)
        self.entity_description = description
        self._attr_unique_id = f"{entry.unique_id}_{description.key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=f"Kickbase {entry.data.get(CONF_LEAGUE_NAME, '')}".strip(),
            manufacturer="Kickbase (inoffizielle API)",
            entry_type=DeviceEntryType.SERVICE,
        )

    @property
    def native_value(self):
        return self.entity_description.value_fn(self.coordinator.data)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        if self.entity_description.attrs_fn is None:
            return None
        return self.entity_description.attrs_fn(self.coordinator.data)
