"""Data models – tolerant parsing of Kickbase's short JSON keys (see Models.swift)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any


def text(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return str(int(value)) if float(value).is_integer() else str(value)
    return None


def num(value: Any) -> float | None:
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


POSITIONS = {1: "TW", 2: "ABW", 3: "MIT", 4: "ST"}


@dataclass(frozen=True)
class League:
    id: str
    name: str
    competition_id: str

    @classmethod
    def from_json(cls, j: dict) -> League:
        return cls(
            id=text(j.get("i")) or "",
            name=text(j.get("n")) or "Liga",
            competition_id=text(j.get("cpi")) or "1",
        )


@dataclass(frozen=True)
class Manager:
    id: str
    name: str
    placement: int
    season_points: float
    team_value: float

    @classmethod
    def from_json(cls, j: dict) -> Manager:
        return cls(
            id=text(j.get("i")) or "",
            name=text(j.get("n")) or "?",
            placement=int(num(j.get("spl")) or 999),
            season_points=num(j.get("sp")) or 0.0,
            team_value=num(j.get("tv")) or 0.0,
        )


@dataclass(frozen=True)
class Player:
    id: str
    first_name: str
    last_name: str
    team_id: str
    position: int
    status: int
    market_value: float
    trend_24h: float
    total_points: float
    average_points: float
    price: float
    expires_at: datetime | None
    offer_count: int
    seller_user_id: str | None
    on_market: bool
    my_offer_price: float | None
    gain_since_purchase: float | None

    @classmethod
    def from_json(cls, p: dict, fetched_at: datetime | None = None) -> Player:
        fetched_at = fetched_at or datetime.now(timezone.utc)
        expires_at = None
        exs = num(p.get("exs"))
        if exs and exs > 0:
            # exs is either seconds until expiry or an epoch timestamp
            expires_at = (
                datetime.fromtimestamp(exs, timezone.utc)
                if exs > 1_000_000
                else fetched_at + timedelta(seconds=exs)
            )
        seller = text((p.get("u") or {}).get("i")) if isinstance(p.get("u"), dict) else None
        my_offer = num(p.get("uop"))
        return cls(
            id=text(p.get("i")) or text(p.get("pi")) or "",
            first_name=(text(p.get("fn")) or "").strip(),
            last_name=(text(p.get("n")) or text(p.get("ln")) or text(p.get("pn")) or "").strip(),
            team_id=text(p.get("tid")) or "",
            position=int(num(p.get("pos")) or 0),
            status=int(num(p.get("st")) or 0),
            market_value=num(p.get("mv")) or 0.0,
            trend_24h=num(p.get("tfhmvt")) or 0.0,
            total_points=num(p.get("p")) or num(p.get("tp")) or 0.0,
            average_points=num(p.get("ap")) or 0.0,
            price=num(p.get("prc")) or 0.0,
            expires_at=expires_at,
            offer_count=int(num(p.get("ofc")) or 0),
            seller_user_id=seller if seller and seller != "0" else None,
            on_market=bool(p.get("iotm")),
            my_offer_price=my_offer if my_offer and my_offer > 0 else None,
            gain_since_purchase=num(p.get("mvgl")),
        )

    @property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}".strip() if self.first_name else self.last_name

    @property
    def position_name(self) -> str:
        return POSITIONS.get(self.position, "?")

    @property
    def is_fit(self) -> bool:
        return self.status == 0
