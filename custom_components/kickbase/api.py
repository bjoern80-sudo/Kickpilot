"""Async client for the unofficial Kickbase API v4 (api.kickbase.com only).

Same endpoints as KickbaseAPI.swift in the macOS app. Credentials are never logged.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
import logging
from typing import Any

import aiohttp

from .lineup import Match, Matchday
from .models import League, Manager, ManagerTransferEntry, MVPoint, Player, PlayerForm, num, text

_LOGGER = logging.getLogger(__name__)

BASE_URL = "https://api.kickbase.com"
TIMEOUT = aiohttp.ClientTimeout(total=30)


class KickbaseError(Exception):
    """Generic API error."""


class KickbaseAuthError(KickbaseError):
    """Wrong e-mail or password."""


class KickbaseApi:
    """Thin async wrapper around the Kickbase v4 endpoints."""

    def __init__(self, session: aiohttp.ClientSession, email: str, password: str) -> None:
        self._session = session
        self._email = email
        self._password = password
        self._token: str | None = None
        self._token_expiry: datetime | None = None
        self._login_lock = asyncio.Lock()
        self.user_id = ""
        self.user_name = ""

    # ---- auth -------------------------------------------------------------

    async def login(self) -> None:
        body = {"em": self._email, "loy": False, "pass": self._password, "rep": {}}
        try:
            async with self._session.post(
                f"{BASE_URL}/v4/user/login",
                json=body,
                headers={"Accept": "application/json"},
                timeout=TIMEOUT,
            ) as resp:
                if resp.status in (401, 403):
                    raise KickbaseAuthError("invalid credentials")
                if resp.status != 200:
                    raise KickbaseError(f"HTTP {resp.status} beim Login")
                data = await resp.json(content_type=None)
        except aiohttp.ClientError as err:
            raise KickbaseError(f"Verbindungsfehler: {err}") from err

        token = text(data.get("tkn")) if isinstance(data, dict) else None
        if not token:
            raise KickbaseError("Unerwartete Antwort beim Login")
        self._token = token
        self._token_expiry = _parse_date(text(data.get("tknex")))
        user = data.get("u") or {}
        self.user_id = text(user.get("id")) or text(user.get("i")) or ""
        self.user_name = text(user.get("name")) or text(user.get("n")) or ""

    def _token_valid(self) -> bool:
        if not self._token:
            return False
        if self._token_expiry is None:
            return True
        return self._token_expiry > datetime.now(timezone.utc) + timedelta(hours=1)

    async def _ensure_login(self) -> None:
        async with self._login_lock:
            if not self._token_valid():
                await self.login()

    # ---- request core -----------------------------------------------------

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, str] | None = None,
        body: dict | None = None,
        retry: bool = True,
    ) -> Any:
        await self._ensure_login()
        headers = {"Accept": "application/json", "Cookie": f"kkstrauth={self._token}"}
        try:
            async with self._session.request(
                method,
                BASE_URL + path,
                params=params,
                json=body,
                headers=headers,
                timeout=TIMEOUT,
            ) as resp:
                if resp.status == 401 and retry:
                    self._token = None
                    return await self._request(method, path, params=params, body=body, retry=False)
                if resp.status not in (200, 201):
                    snippet = (await resp.text())[:200]
                    raise KickbaseError(f"HTTP {resp.status}: {snippet}")
                raw = await resp.read()
                if not raw:
                    return None
                try:
                    return await resp.json(content_type=None)
                except ValueError:
                    return None
        except aiohttp.ClientError as err:
            raise KickbaseError(f"Verbindungsfehler: {err}") from err

    async def _get(self, path: str, params: dict[str, str] | None = None) -> dict:
        data = await self._request("GET", path, params=params)
        return data if isinstance(data, dict) else {}

    # ---- read -------------------------------------------------------------

    async def leagues(self) -> list[League]:
        j = await self._get("/v4/leagues/selection")
        return [League.from_json(x) for x in _arr(j.get("it"))]

    async def budget(self, league: str) -> float:
        j = await self._get(f"/v4/leagues/{league}/me/budget")
        return num(j.get("b")) or 0.0

    async def squad(self, league: str) -> list[Player]:
        j = await self._get(f"/v4/leagues/{league}/squad")
        now = datetime.now(timezone.utc)
        return [Player.from_json(x, now) for x in _arr(j.get("it"))]

    async def market(self, league: str) -> list[Player]:
        j = await self._get(f"/v4/leagues/{league}/market")
        now = datetime.now(timezone.utc)
        return [Player.from_json(x, now) for x in _arr(j.get("it"))]

    async def ranking(self, league: str) -> list[Manager]:
        j = await self._get(f"/v4/leagues/{league}/ranking")
        managers = [Manager.from_json(x) for x in _arr(j.get("us"))]
        return sorted(managers, key=lambda m: m.placement)

    async def team_table(self, competition_id: str = "1") -> dict[str, tuple[str, int]]:
        """Vereins-ID → (Kurzname `tn`, Tabellenplatz `cpl`) aus der Tabelle des Wettbewerbs."""
        j = await self._get(f"/v4/competitions/{competition_id}/table")
        out: dict[str, tuple[str, int]] = {}
        for row in j.get("it") or []:
            if isinstance(row, dict) and (tid := text(row.get("tid"))):
                out[tid] = (text(row.get("tn")) or tid, int(num(row.get("cpl")) or 0))
        return out

    async def manager_squad(self, league: str, user_id: str) -> list[Player]:
        """Another manager's squad (`pi`/`pn` instead of `i`/`n`)."""
        j = await self._get(f"/v4/leagues/{league}/managers/{user_id}/squad")
        return [Player.from_json(x) for x in _arr(j.get("it"))]

    async def lineup_forms(self, league: str) -> dict[str, PlayerForm]:
        """Own squad from /lineup: per player `ap` and `ph` (last 5 matchdays)."""
        j = await self._get(f"/v4/leagues/{league}/lineup")
        forms = (PlayerForm.from_json(x) for x in _arr(j.get("it")))
        return {f.player_id: f for f in forms if f.player_id}

    async def player_form(self, league: str, player_id: str) -> PlayerForm:
        """Any player via /players/{id} (market players have no `ap` in the market list)."""
        return PlayerForm.from_json(await self._get(f"/v4/leagues/{league}/players/{player_id}"), player_id)

    async def matchdays(self, competition_id: str = "1") -> list[Matchday]:
        """Season schedule: `it[]` = matchdays with `day` and `it[]` = matches
        (`mi`, `dt` kick-off, `t1`/`t2` club ids, `st` 0 not started / 2 finished)."""
        j = await self._get(f"/v4/competitions/{competition_id}/matchdays")
        days: list[Matchday] = []
        for d in _arr(j.get("it")):
            day = int(num(d.get("day")) or 0)
            matches = []
            for m in _arr(d.get("it")):
                kickoff = _parse_date(text(m.get("dt")))
                if kickoff is None:
                    continue
                matches.append(
                    Match(
                        match_id=text(m.get("mi")) or "",
                        matchday=int(num(m.get("day")) or day),
                        kickoff=kickoff,
                        home_id=text(m.get("t1")) or "",
                        away_id=text(m.get("t2")) or "",
                        status=int(num(m.get("st")) or 0),
                    )
                )
            if day and matches:
                days.append(Matchday(day, matches))
        return days

    async def manager_transfers(
        self, league: str, user_id: str, start: int
    ) -> list[ManagerTransferEntry]:
        """One page (25 entries) of a manager's transfers, newest first."""
        j = await self._get(
            f"/v4/leagues/{league}/managers/{user_id}/transfer", {"start": str(start)}
        )
        entries = (ManagerTransferEntry.from_json(x, user_id) for x in _arr(j.get("it")))
        return [e for e in entries if e is not None]

    async def market_value_history(self, league: str, player_id: str) -> list[MVPoint]:
        """Only timeframe 365 returns data. Entries: {dt: days since epoch, mv}."""
        j = await self._get(f"/v4/leagues/{league}/players/{player_id}/marketvalue/365")
        points = []
        for e in _arr(j.get("it")):
            dt, mv = num(e.get("dt")), num(e.get("mv"))
            if dt is None or not mv or mv <= 0:
                continue
            points.append(MVPoint(datetime.fromtimestamp(dt * 86_400, timezone.utc), mv))
        return sorted(points, key=lambda p: p.date)

    # ---- write: REAL transactions (only called from automation.py) ------------

    async def place_offer(self, league: str, player_id: str, price: int) -> None:
        await self._request("POST", f"/v4/leagues/{league}/market/{player_id}/offers", body={"price": price})

    async def list_for_sale(self, league: str, player_id: str, price: int) -> None:
        """Lists one of my players on the transfer market."""
        await self._request("POST", f"/v4/leagues/{league}/market/", body={"pi": player_id, "prc": price})

    async def sell_to_kickbase(self, league: str, player_id: str) -> None:
        """Accepts Kickbase's instant offer for a listed player – immediate sale."""
        await self._request("POST", f"/v4/leagues/{league}/market/{player_id}/sell", body={})


def _arr(value: Any) -> list[dict]:
    if not isinstance(value, list):
        return []
    return [x for x in value if isinstance(x, dict)]


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
