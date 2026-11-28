"""Constants for the Kickbase integration."""

from __future__ import annotations

DOMAIN = "kickbase"

CONF_LEAGUE_ID = "league_id"
CONF_LEAGUE_NAME = "league_name"

# Options (all editable later via the options flow)
OPT_SCAN_INTERVAL = "scan_interval"  # minutes
OPT_CHECK_TIMES = "check_times"  # "00:05, 08:00, 22:45"
OPT_FRIDAY_TIMES = "friday_times"  # "13:00, 17:00"
OPT_WARNING_HOURS = "warning_hours"
OPT_MV_FETCH_TIME = "mv_fetch_time"  # "22:30"
OPT_CONFIRM_VALID_HOURS = "confirm_valid_hours"
OPT_NOTIFY_TARGETS = "notify_targets"  # ["notify.mobile_app_..."]
OPT_MODE_BIDS = "mode_bids"  # MODE_SEMI | MODE_FULL
OPT_MODE_SALES = "mode_sales"
OPT_FULL_AUTO_ACK = "full_auto_ack"
OPT_MAX_BIDS_PER_RUN = "max_bids_per_run"
OPT_MAX_BID_SUM_PER_DAY = "max_bid_sum_per_day"
OPT_MAX_SALES_PER_FRIDAY = "max_sales_per_friday"
OPT_DRY_RUN = "dry_run"
OPT_DESIGN = "design"  # DESIGN_APP | DESIGN_HA (look of the Kickpilot card)
OPT_LINEUP_WARN = "lineup_warn"  # warn before kick-off if the starting eleven has problems
OPT_LINEUP_LEAD_HOURS = "lineup_lead_hours"

MODE_SEMI = "semi"
MODE_FULL = "full"

DESIGN_APP = "app"
DESIGN_HA = "ha"

DEFAULT_OPTIONS: dict = {
    OPT_SCAN_INTERVAL: 15,
    OPT_CHECK_TIMES: "00:05, 08:00, 22:45",
    OPT_FRIDAY_TIMES: "13:00, 17:00",
    OPT_WARNING_HOURS: 6,
    OPT_MV_FETCH_TIME: "22:30",
    OPT_CONFIRM_VALID_HOURS: 2,
    OPT_NOTIFY_TARGETS: [],
    OPT_MODE_BIDS: MODE_SEMI,
    OPT_MODE_SALES: MODE_SEMI,
    OPT_FULL_AUTO_ACK: False,
    OPT_MAX_BIDS_PER_RUN: 3,
    OPT_MAX_BID_SUM_PER_DAY: 20_000_000,
    OPT_MAX_SALES_PER_FRIDAY: 3,
    OPT_DRY_RUN: True,
    OPT_DESIGN: DESIGN_APP,
    OPT_LINEUP_WARN: True,
    OPT_LINEUP_LEAD_HOURS: 2,
}

MIN_SCAN_INTERVAL = 5
MAX_SCAN_INTERVAL = 120

TIMEZONE = "Europe/Berlin"

# League rules: see AutoRules in planner.py (same as AutoTransfer.swift in the macOS app).


def opt(options: dict, key: str):
    """Option value with default."""
    return options.get(key, DEFAULT_OPTIONS[key])


def parse_times(value: str) -> list[tuple[int, int]]:
    """Parse "08:00, 22:45" into [(8, 0), (22, 45)]. Raises ValueError on bad input."""
    result: list[tuple[int, int]] = []
    for part in (value or "").replace(";", ",").split(","):
        part = part.strip()
        if not part:
            continue
        hh, _, mm = part.partition(":")
        h, m = int(hh), int(mm or 0)
        if not (0 <= h <= 23 and 0 <= m <= 59):
            raise ValueError(part)
        result.append((h, m))
    return sorted(set(result))
