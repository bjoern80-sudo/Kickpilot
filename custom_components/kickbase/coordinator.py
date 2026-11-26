"""Data coordinator: loads budget, squad, market and ranking in the configured interval."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import datetime, timedelta
import logging
from zoneinfo import ZoneInfo

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed
from homeassistant.util import dt as dt_util

from .api import KickbaseApi, KickbaseAuthError, KickbaseError
from .const import (
    CONF_LEAGUE_ID,
    DEADLINE_HOUR,
    DEADLINE_WEEKDAY,
    DOMAIN,
    OPT_SCAN_INTERVAL,
    TIMEZONE,
    opt,
)
from .models import Manager, Player

_LOGGER = logging.getLogger(__name__)


@dataclass
class KickbaseData:
    budget: float = 0.0
    squad: list[Player] = field(default_factory=list)
    market: list[Player] = field(default_factory=list)
    managers: list[Manager] = field(default_factory=list)
    my_user_id: str = ""
    updated: datetime | None = None

    @property
    def team_value(self) -> float:
        return sum(p.market_value for p in self.squad)

    @property
    def me(self) -> Manager | None:
        return next((m for m in self.managers if m.id == self.my_user_id), None)


def next_deadline(now: datetime | None = None) -> datetime:
    """Next Friday 19:00 Europe/Berlin (today if it is Friday before 19:00)."""
    tz = ZoneInfo(TIMEZONE)
    now = (now or dt_util.utcnow()).astimezone(tz)
    days = (DEADLINE_WEEKDAY - now.weekday()) % 7
    candidate = (now + timedelta(days=days)).replace(
        hour=DEADLINE_HOUR, minute=0, second=0, microsecond=0
    )
    if candidate <= now:
        candidate += timedelta(days=7)
    return candidate


class KickbaseCoordinator(DataUpdateCoordinator[KickbaseData]):
    """Fetches the frequently changing data."""

    config_entry: ConfigEntry

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry, api: KickbaseApi) -> None:
        super().__init__(
            hass,
            _LOGGER,
            config_entry=entry,
            name=DOMAIN,
            update_interval=timedelta(minutes=opt(entry.options, OPT_SCAN_INTERVAL)),
        )
        self.api = api
        self.league_id: str = entry.data[CONF_LEAGUE_ID]

    async def _async_update_data(self) -> KickbaseData:
        league = self.league_id
        try:
            budget, squad, market, managers = await asyncio.gather(
                self.api.budget(league),
                self.api.squad(league),
                self.api.market(league),
                self.api.ranking(league),
            )
        except KickbaseAuthError as err:
            raise ConfigEntryAuthFailed("Kickbase-Anmeldung fehlgeschlagen") from err
        except KickbaseError as err:
            raise UpdateFailed(str(err)) from err
        return KickbaseData(
            budget=budget,
            squad=squad,
            market=market,
            managers=managers,
            my_user_id=self.api.user_id,
            updated=dt_util.utcnow(),
        )
