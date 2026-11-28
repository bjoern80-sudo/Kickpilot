"""Lineup guard: checks the starting eleven before kick-off (read-only, never changes the lineup).

1:1 port of `LineupCheck.swift` in the macOS app – change rules in BOTH files.

The lineup has to be set before the FIRST kick-off of a matchday (usually Friday 20:30) and then
counts for the whole matchday (league rule, confirmed by the user). Problems (trigger a warning):
* starting eleven incomplete (< 11 players)
* starter not fit (injured, stricken, suspended, …)
* starter's club has no match on this matchday
Tips (shown, but never trigger a warning on their own):
* a fit bench player of the same position averages clearly more points
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta

from .models import Player


class LineupRules:
    starting_size = 11
    # Bench player must average at least this many points more than the starter (tip).
    tip_min_avg_gain = 20.0
    # Default: warn this many hours before the first kick-off of the matchday.
    default_lead_hours = 2.0


STATUS_TEXT = {
    0: "fit",
    1: "verletzt",
    2: "angeschlagen",
    4: "Aufbautraining",
    8: "Rot-Sperre",
    16: "Gelb-Rot-Sperre",
    32: "Gelb-Sperre",
    64: "nicht im Kader",
    128: "nicht in Liga",
    256: "abwesend",
}


def status_text(status: int) -> str:
    return STATUS_TEXT.get(status, f"Status {status}")


@dataclass(frozen=True)
class Match:
    match_id: str
    matchday: int
    kickoff: datetime
    home_id: str
    away_id: str
    status: int  # 0 not started, 2 finished (1 presumably live)

    @property
    def started(self) -> bool:
        return self.status != 0


@dataclass
class Matchday:
    day: int
    matches: list[Match]

    def kickoff_of(self, team_id: str) -> Match | None:
        return next((m for m in self.matches if team_id in (m.home_id, m.away_id)), None)


def current_matchday(days: list[Matchday]) -> Matchday | None:
    """First matchday (by number) that still has a match that is not finished."""
    for d in sorted(days, key=lambda d: d.day):
        if any(m.status != 2 for m in d.matches):
            return d
    return None


@dataclass(frozen=True)
class LineupIssue:
    kind: str  # "unvollstaendig" | "nicht_fit" | "kein_spiel" | "tipp"
    text: str
    player: Player | None = None
    replacement: Player | None = None
    # Last moment the issue can be fixed: first kick-off of the matchday.
    deadline: datetime | None = None

    @property
    def is_problem(self) -> bool:
        return self.kind != "tipp"

    @property
    def key(self) -> str:
        """Identifies the issue for "warn only once"."""
        pid = self.player.id if self.player else ""
        return f"{self.kind}:{pid}:{self.deadline.isoformat() if self.deadline else ''}"


@dataclass
class LineupCheck:
    matchday: int | None = None
    # First kick-off of the matchday = the lineup is locked from then on (None: already locked).
    lock_at: datetime | None = None
    locked: bool = False
    starters: int = 0
    issues: list[LineupIssue] = field(default_factory=list)

    @property
    def problems(self) -> list[LineupIssue]:
        return [i for i in self.issues if i.is_problem]

    @property
    def tips(self) -> list[LineupIssue]:
        return [i for i in self.issues if not i.is_problem]

    def due(self, now: datetime, lead_hours: float) -> list[LineupIssue]:
        """Issues whose deadline is within `lead_hours` (and not yet passed)."""
        return [
            i
            for i in self.issues
            if i.deadline is not None and now < i.deadline <= now + timedelta(hours=lead_hours)
        ]


def _name(p: Player) -> str:
    return f"{p.full_name} ({p.position_name})"


def check_lineup(squad: list[Player], matchday: Matchday | None, now: datetime) -> LineupCheck:
    result = LineupCheck()
    if matchday is None:
        return result
    result.matchday = matchday.day
    first = min((m.kickoff for m in matchday.matches), default=None)
    starters = [p for p in squad if p.lineup_slot is not None]
    bench = [p for p in squad if p.lineup_slot is None]
    result.starters = len(starters)
    if first is None or first <= now or any(m.started for m in matchday.matches):
        result.locked = True  # matchday running – lineup counts as set
        return result
    result.lock_at = first

    def plays(p: Player) -> bool:
        return matchday.kickoff_of(p.team_id) is not None

    used: set[str] = set()

    def best_bench(position: int, better_than: float | None = None) -> Player | None:
        candidates = [
            b
            for b in bench
            if b.position == position and b.is_fit and plays(b) and b.id not in used
            and (better_than is None or b.average_points >= better_than)
        ]
        best = max(candidates, key=lambda b: b.average_points, default=None)
        if best is not None:
            used.add(best.id)
        return best

    if len(starters) < LineupRules.starting_size:
        result.issues.append(
            LineupIssue(
                "unvollstaendig",
                f"Startelf unvollständig: {len(starters)} von {LineupRules.starting_size} Plätzen besetzt",
                deadline=first,
            )
        )

    # Weakest first, so the best replacement goes to the most urgent slot.
    by_avg = sorted(starters, key=lambda p: p.average_points)
    for p in by_avg:
        if not plays(p):
            result.issues.append(
                LineupIssue(
                    "kein_spiel",
                    f"{_name(p)}: Verein hat an diesem Spieltag kein Spiel",
                    p,
                    best_bench(p.position),
                    deadline=first,
                )
            )
        elif not p.is_fit:
            result.issues.append(
                LineupIssue(
                    "nicht_fit", f"{_name(p)} ist {status_text(p.status)}", p, best_bench(p.position), deadline=first
                )
            )

    for p in by_avg:
        if not (plays(p) and p.is_fit):
            continue
        sub = best_bench(p.position, better_than=p.average_points + LineupRules.tip_min_avg_gain)
        if sub is not None:
            result.issues.append(
                LineupIssue(
                    "tipp",
                    f"{sub.full_name} (Ø {sub.average_points:.0f}) statt {p.full_name} (Ø {p.average_points:.0f})",
                    p,
                    sub,
                    deadline=first,
                )
            )
    return result
