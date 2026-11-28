"""Kickbase sensors: key figures, proposals and data status."""

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
from homeassistant.const import EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import KickbaseConfigEntry
from .coordinator import KickbaseCoordinator, KickbaseData
from .entity import KickbaseEntity
from .planner import AutoRules, next_deadline


def _iso(d: datetime | None) -> str | None:
    return d.isoformat() if d else None


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
                "verein": p.team_id,
                "startelf": p.lineup_slot,
                "prognose": round(d.forecasts[p.id]) if p.id in d.forecasts else None,
            }
            for p in players
        ],
        "prognose_spieltag": d.forecast_matchday,
        "vereine": {
            tid: d.team_names[tid]
            for tid in sorted({p.team_id for p in (*d.squad, *d.market)})
            if tid in d.team_names
        },
    }


def _bid_attrs(d: KickbaseData) -> dict[str, Any]:
    return {
        "gebote": [
            {
                "id": p.id,
                "name": p.full_name,
                "verein": p.team_id,
                "gebot": round(p.my_offer_price or 0),
                "marktwert": round(p.market_value),
                "endet": _iso(p.expires_at),
            }
            for p in d.market
            if p.my_offer_price
        ]
    }


def _buy_attrs(d: KickbaseData) -> dict[str, Any]:
    plan = d.plan
    if plan is None:
        return {}
    return {
        "plan_id": plan.buys_id,
        "summe": round(plan.total_bids),
        "erwarteter_gewinn": round(sum(b.expected_gain for b in plan.buys)),
        "staerkster_konkurrent": plan.competitor_name,
        "konkurrent_aufpreis_pct": round(plan.competitor_pct, 1),
        "vorschlaege": [
            {
                "id": b.player.id,
                "name": b.player.full_name,
                "verein": b.player.team_id,
                "position": b.player.position_name,
                "marktwert": round(b.player.market_value),
                "gebot": round(b.bid),
                "aufpreis_pct": round(b.bid_over_mv_pct, 1),
                "erwarteter_gewinn": round(b.expected_gain),
                "muster": b.trend.pattern,
                "zuwachs_3t_pct": round(b.momentum_pct, 1),
                "hochpunkt": round(b.trend.peak) if b.trend.peak else None,
                "endet": _iso(b.player.expires_at),
                "nach_frist": b.after_deadline,
            }
            for b in plan.buys
        ],
        "uebersprungen": len(plan.skipped),
        "warten_auf_ablauftag": sum(1 for s in plan.skipped if s.reason == "Angebot endet nicht heute"),
        "backtest_trefferquote_pct": round(plan.backtest.all.hit_rate),
        "backtest_signale": plan.backtest.all.signals,
        "backtest_gewinn_pct": round(plan.backtest.all.avg_profit_pct, 1),
    }


def _sale_attrs(d: KickbaseData) -> dict[str, Any]:
    plan = d.plan
    if plan is None:
        return {}
    return {
        "plan_id": plan.sales_id,
        "budget_nach_geboten": round(plan.committed_budget),
        "budget_nach_verkaeufen": round(plan.budget_after_sales),
        "vorschlaege": [
            {
                "id": s.player.id,
                "name": s.player.full_name,
                "verein": s.player.team_id,
                "position": s.player.position_name,
                "erloes": round(s.expected_proceeds),
                "gewinn_pct": round(s.gain_pct, 1),
                "basis": s.gain_basis,
            }
            for s in plan.sales
        ],
    }


def _upgrade_attrs(d: KickbaseData) -> dict[str, Any]:
    return {
        "spieltag": d.forecast_matchday,
        "summe": round(sum(u.bid for u in d.upgrades)),
        "vorschlaege": [
            {
                "id": u.player.id,
                "name": u.player.full_name,
                "verein": u.player.team_id,
                "position": u.player.position_name,
                "marktwert": round(u.player.market_value),
                "gebot": round(u.bid),
                "prognose": round(u.forecast),
                "statt": u.replaces.full_name,
                "statt_prognose": round(u.replaces_forecast),
                "plus_punkte": round(u.gain),
                "endet": _iso(u.player.expires_at),
                "nach_frist": u.after_deadline,
            }
            for u in d.upgrades
        ],
    }


def _trend_attrs(d: KickbaseData) -> dict[str, Any]:
    return {
        "vorschlaege": [
            {
                "id": t.player.id,
                "name": t.player.full_name,
                "verein": t.player.team_id,
                "position": t.player.position_name,
                "erloes": round(t.proceeds),
                "unter_hoch_pct": round(t.drop_pct, 1),
                "hoch": round(t.peak),
                "hoch_am": _iso(t.peak_date),
            }
            for t in d.trend_sales
        ]
    }


def _radar_attrs(d: KickbaseData) -> dict[str, Any]:
    return {
        "manager": [
            {
                "name": r.manager.name,
                "ich": r.is_me,
                "platz": r.manager.placement,
                "punkte": round(r.manager.season_points),
                "abstand": round(r.gap_to_first),
                "abstand_nach_oben": round(r.gap_to_above) if r.gap_to_above is not None else None,
                "spieltag_punkte": round(r.manager.matchday_points),
                "spieltag_platz": r.manager.matchday_placement,
                "teamwert": round(r.manager.team_value),
                "verletzt_in_startelf": r.injured_starters,
            }
            for r in d.radar
        ]
    }


def _my_gap(d: KickbaseData) -> int | None:
    me = next((r for r in d.radar if r.is_me), None)
    return round(me.gap_to_first) if me else None


def _capital_attrs(d: KickbaseData) -> dict[str, Any]:
    c = d.capital
    if c is None:
        return {}
    return {
        "zuwachs_pro_tag": round(c.daily_growth),
        "winterpause": _iso(c.winter_break),
        "kapital_winterpause": round(c.capital_winter) if c.capital_winter is not None else None,
        "saisonende": _iso(c.season_end),
        "kapital_saisonende": round(c.capital_end) if c.capital_end is not None else None,
        "kaufkraft": round(c.buying_power),
        "kaufkraft_winterpause": round(c.buying_power_winter) if c.buying_power_winter is not None else None,
    }


@dataclass(frozen=True, kw_only=True)
class KickbaseSensorDescription(SensorEntityDescription):
    value_fn: Callable[[KickbaseData], float | int | str | datetime | None]
    attrs_fn: Callable[[KickbaseData], dict[str, Any]] | None = None


EURO = {
    "device_class": SensorDeviceClass.MONETARY,
    "native_unit_of_measurement": "EUR",
    "state_class": SensorStateClass.TOTAL,
    "suggested_display_precision": 0,
}


def _plan_value(fn: Callable) -> Callable[[KickbaseData], Any]:
    return lambda d: fn(d.plan) if d.plan else None


SENSORS: tuple[KickbaseSensorDescription, ...] = (
    KickbaseSensorDescription(key="budget", translation_key="budget", value_fn=lambda d: d.budget, **EURO),
    KickbaseSensorDescription(
        key="team_value", translation_key="team_value", value_fn=lambda d: d.team_value, **EURO
    ),
    KickbaseSensorDescription(
        key="budget_after_bids",
        translation_key="budget_after_bids",
        value_fn=_plan_value(lambda p: p.committed_budget),
        **EURO,
    ),
    KickbaseSensorDescription(
        key="open_bids",
        translation_key="open_bids",
        value_fn=lambda d: sum(p.my_offer_price or 0 for p in d.market),
        attrs_fn=_bid_attrs,
        **EURO,
    ),
    KickbaseSensorDescription(
        key="debt_limit",
        translation_key="debt_limit",
        value_fn=lambda d: -AutoRules.max_debt_share_of_team_value * d.team_value,
        **EURO,
    ),
    KickbaseSensorDescription(
        key="bid_limit",
        translation_key="bid_limit",
        value_fn=_plan_value(lambda p: p.bid_limit),
        attrs_fn=lambda d: {
            "reserve_ausserhalb_top11": round(d.plan.reserve),
            "spielraum_bis_minus_grenze": round(d.plan.global_limit),
        }
        if d.plan
        else {},
        **EURO,
    ),
    KickbaseSensorDescription(
        key="buy_proposals",
        translation_key="buy_proposals",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=_plan_value(lambda p: len(p.buys)),
        attrs_fn=_buy_attrs,
    ),
    KickbaseSensorDescription(
        key="sale_proposals",
        translation_key="sale_proposals",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=_plan_value(lambda p: len(p.sales)),
        attrs_fn=_sale_attrs,
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
        key="upgrade_proposals",
        translation_key="upgrade_proposals",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda d: len(d.upgrades),
        attrs_fn=_upgrade_attrs,
    ),
    KickbaseSensorDescription(
        key="trend_sales",
        translation_key="trend_sales",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda d: len(d.trend_sales),
        attrs_fn=_trend_attrs,
    ),
    KickbaseSensorDescription(
        key="league_gap",
        translation_key="league_gap",
        state_class=SensorStateClass.MEASUREMENT,
        native_unit_of_measurement="Pkt.",
        value_fn=_my_gap,
        attrs_fn=_radar_attrs,
    ),
    KickbaseSensorDescription(
        key="capital",
        translation_key="capital",
        value_fn=lambda d: d.capital.capital if d.capital else None,
        attrs_fn=_capital_attrs,
        **EURO,
    ),
    KickbaseSensorDescription(
        key="squad_size",
        translation_key="squad_size",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda d: len(d.squad),
        attrs_fn=_squad_attrs,
    ),
    KickbaseSensorDescription(
        key="data_status",
        translation_key="data_status",
        device_class=SensorDeviceClass.TIMESTAMP,
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda d: d.history_loaded_at,
        attrs_fn=lambda d: {
            "transfers": d.transfer_count,
            "bieterprofile": [
                {
                    "name": p.name,
                    "kaeufe_mit_verlauf": p.samples,
                    "aufpreis_median_pct": round(p.median_overpay, 1)
                    if p.median_overpay is not None
                    else None,
                    "aufpreis_p75_pct": round(p.typical_high_overpay, 1)
                    if p.typical_high_overpay is not None
                    else None,
                    "kaeufe_pro_woche": round(p.buys_per_week, 1),
                }
                for p in d.profiles
            ],
        },
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: KickbaseConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    coordinator = entry.runtime_data
    async_add_entities(KickbaseSensor(coordinator, entry, desc) for desc in SENSORS)


class KickbaseSensor(KickbaseEntity, SensorEntity):
    entity_description: KickbaseSensorDescription

    def __init__(
        self,
        coordinator: KickbaseCoordinator,
        entry: KickbaseConfigEntry,
        description: KickbaseSensorDescription,
    ) -> None:
        super().__init__(coordinator, entry, description.key)
        self.entity_description = description

    @property
    def native_value(self):
        return self.entity_description.value_fn(self.coordinator.data)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        if self.entity_description.attrs_fn is None:
            return None
        return self.entity_description.attrs_fn(self.coordinator.data)
