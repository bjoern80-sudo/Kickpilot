"""Config flow (setup, re-auth) and options flow (rhythm, notifications, mode)."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

import aiohttp
import voluptuous as vol

from homeassistant.config_entries import ConfigEntry, ConfigFlow, ConfigFlowResult, OptionsFlow
from homeassistant.const import CONF_EMAIL, CONF_PASSWORD
from homeassistant.core import callback
from homeassistant.helpers.aiohttp_client import async_create_clientsession
from homeassistant.helpers.selector import (
    BooleanSelector,
    NumberSelector,
    NumberSelectorConfig,
    NumberSelectorMode,
    SelectOptionDict,
    SelectSelector,
    SelectSelectorConfig,
    SelectSelectorMode,
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)

from .api import KickbaseApi, KickbaseAuthError, KickbaseError
from .const import (
    CONF_LEAGUE_ID,
    CONF_LEAGUE_NAME,
    DEFAULT_OPTIONS,
    DOMAIN,
    MAX_SCAN_INTERVAL,
    MIN_SCAN_INTERVAL,
    MODE_FULL,
    MODE_SEMI,
    OPT_CHECK_TIMES,
    OPT_CONFIRM_VALID_HOURS,
    OPT_DRY_RUN,
    OPT_FRIDAY_TIMES,
    OPT_FULL_AUTO_ACK,
    OPT_MAX_BID_SUM_PER_DAY,
    OPT_MAX_BIDS_PER_RUN,
    OPT_MAX_SALES_PER_FRIDAY,
    OPT_MODE_BIDS,
    OPT_MODE_SALES,
    OPT_MV_FETCH_TIME,
    OPT_NOTIFY_TARGETS,
    OPT_SCAN_INTERVAL,
    OPT_WARNING_HOURS,
    parse_times,
)
from .models import League

CREDENTIALS_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_EMAIL): TextSelector(TextSelectorConfig(type=TextSelectorType.EMAIL)),
        vol.Required(CONF_PASSWORD): TextSelector(
            TextSelectorConfig(type=TextSelectorType.PASSWORD)
        ),
    }
)


async def _login(hass, email: str, password: str) -> tuple[KickbaseApi, list[League]]:
    session = async_create_clientsession(hass, cookie_jar=aiohttp.DummyCookieJar())
    api = KickbaseApi(session, email, password)
    await api.login()
    return api, await api.leagues()


class KickbaseConfigFlow(ConfigFlow, domain=DOMAIN):
    """Set up Kickbase: credentials, then league."""

    VERSION = 1

    def __init__(self) -> None:
        self._credentials: dict[str, str] = {}
        self._user_id = ""
        self._leagues: list[League] = []

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                api, leagues = await _login(
                    self.hass, user_input[CONF_EMAIL], user_input[CONF_PASSWORD]
                )
            except KickbaseAuthError:
                errors["base"] = "invalid_auth"
            except KickbaseError:
                errors["base"] = "cannot_connect"
            else:
                if not leagues:
                    return self.async_abort(reason="no_leagues")
                self._credentials = dict(user_input)
                self._user_id = api.user_id
                self._leagues = leagues
                if len(leagues) == 1:
                    return await self._create(leagues[0])
                return await self.async_step_league()
        return self.async_show_form(
            step_id="user",
            data_schema=self.add_suggested_values_to_schema(CREDENTIALS_SCHEMA, user_input),
            errors=errors,
        )

    async def async_step_league(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is not None:
            league = next(l for l in self._leagues if l.id == user_input[CONF_LEAGUE_ID])
            return await self._create(league)
        options = [SelectOptionDict(value=l.id, label=l.name) for l in self._leagues]
        return self.async_show_form(
            step_id="league",
            data_schema=vol.Schema(
                {vol.Required(CONF_LEAGUE_ID): SelectSelector(SelectSelectorConfig(options=options))}
            ),
        )

    async def _create(self, league: League) -> ConfigFlowResult:
        await self.async_set_unique_id(f"{self._user_id}_{league.id}")
        self._abort_if_unique_id_configured()
        return self.async_create_entry(
            title=f"Kickbase {league.name}",
            data={**self._credentials, CONF_LEAGUE_ID: league.id, CONF_LEAGUE_NAME: league.name},
            options=dict(DEFAULT_OPTIONS),
        )

    # ---- re-auth (password changed) ----------------------------------------

    async def async_step_reauth(self, entry_data: Mapping[str, Any]) -> ConfigFlowResult:
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        entry = self._get_reauth_entry()
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                await _login(self.hass, entry.data[CONF_EMAIL], user_input[CONF_PASSWORD])
            except KickbaseAuthError:
                errors["base"] = "invalid_auth"
            except KickbaseError:
                errors["base"] = "cannot_connect"
            else:
                return self.async_update_reload_and_abort(
                    entry, data_updates={CONF_PASSWORD: user_input[CONF_PASSWORD]}
                )
        return self.async_show_form(
            step_id="reauth_confirm",
            data_schema=vol.Schema(
                {
                    vol.Required(CONF_PASSWORD): TextSelector(
                        TextSelectorConfig(type=TextSelectorType.PASSWORD)
                    )
                }
            ),
            description_placeholders={"email": entry.data[CONF_EMAIL]},
            errors=errors,
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        return KickbaseOptionsFlow()


def _number(minimum: float, maximum: float, step: float, unit: str | None = None) -> NumberSelector:
    return NumberSelector(
        NumberSelectorConfig(
            min=minimum, max=maximum, step=step, mode=NumberSelectorMode.BOX, unit_of_measurement=unit
        )
    )


class KickbaseOptionsFlow(OptionsFlow):
    """All settings that can be changed at any time."""

    def _notify_options(self) -> list[SelectOptionDict]:
        services = self.hass.services.async_services_for_domain("notify")
        return [
            SelectOptionDict(value=f"notify.{name}", label=f"notify.{name}")
            for name in sorted(services)
            if name not in ("send_message", "persistent_notification")
        ]

    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            for key in (OPT_CHECK_TIMES, OPT_FRIDAY_TIMES, OPT_MV_FETCH_TIME):
                try:
                    times = parse_times(user_input.get(key, ""))
                except ValueError:
                    errors[key] = "invalid_times"
                    continue
                if key == OPT_MV_FETCH_TIME and len(times) != 1:
                    errors[key] = "single_time"
            full = MODE_FULL in (user_input.get(OPT_MODE_BIDS), user_input.get(OPT_MODE_SALES))
            if full and not user_input.get(OPT_FULL_AUTO_ACK):
                errors[OPT_FULL_AUTO_ACK] = "full_auto_ack_required"
            if not errors:
                if not full:
                    user_input[OPT_FULL_AUTO_ACK] = False
                for key in (
                    OPT_SCAN_INTERVAL,
                    OPT_WARNING_HOURS,
                    OPT_CONFIRM_VALID_HOURS,
                    OPT_MAX_BIDS_PER_RUN,
                    OPT_MAX_BID_SUM_PER_DAY,
                    OPT_MAX_SALES_PER_FRIDAY,
                ):
                    user_input[key] = int(user_input[key])
                return self.async_create_entry(data={**DEFAULT_OPTIONS, **user_input})

        mode = SelectSelector(
            SelectSelectorConfig(
                options=[MODE_SEMI, MODE_FULL],
                translation_key="mode",
                mode=SelectSelectorMode.LIST,
            )
        )
        schema = vol.Schema(
            {
                vol.Required(OPT_SCAN_INTERVAL): _number(MIN_SCAN_INTERVAL, MAX_SCAN_INTERVAL, 5, "min"),
                vol.Required(OPT_CHECK_TIMES): TextSelector(),
                vol.Required(OPT_FRIDAY_TIMES): TextSelector(),
                vol.Required(OPT_WARNING_HOURS): _number(1, 48, 1, "h"),
                vol.Required(OPT_MV_FETCH_TIME): TextSelector(),
                vol.Optional(OPT_NOTIFY_TARGETS): SelectSelector(
                    SelectSelectorConfig(
                        options=self._notify_options(),
                        multiple=True,
                        mode=SelectSelectorMode.DROPDOWN,
                        custom_value=True,
                    )
                ),
                vol.Required(OPT_MODE_BIDS): mode,
                vol.Required(OPT_MODE_SALES): mode,
                vol.Required(OPT_FULL_AUTO_ACK): BooleanSelector(),
                vol.Required(OPT_MAX_BIDS_PER_RUN): _number(1, 10, 1),
                vol.Required(OPT_MAX_BID_SUM_PER_DAY): _number(0, 500_000_000, 1_000_000, "€"),
                vol.Required(OPT_MAX_SALES_PER_FRIDAY): _number(1, 10, 1),
                vol.Required(OPT_CONFIRM_VALID_HOURS): _number(1, 24, 1, "h"),
                vol.Required(OPT_DRY_RUN): BooleanSelector(),
            }
        )
        current = {**DEFAULT_OPTIONS, **self.config_entry.options, **(user_input or {})}
        return self.async_show_form(
            step_id="init",
            data_schema=self.add_suggested_values_to_schema(schema, current),
            errors=errors,
        )
