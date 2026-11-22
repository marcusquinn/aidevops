#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Same-login foreign-device evidence already present in the local pulse log.

GH#37888: the pulse logs claims it reads, so no API call is needed. Positive
evidence is either:
  - `CLAIM_LOST: runner=<self> lost to <self>`: dispatch-claim-helper.sh reports
    a same-runner winner on this device as CLAIM_STALE_SELF, so a same-runner
    loss proves a claim from another device; or
  - a pulse-issue-reconcile-stale.sh cross-runner guard/expiry line whose
    `runner=` equals `self=` but whose `device=` is not the local device.
Only lines within the lookback count. Absence of evidence is `unknown`, never
`none`: the log shows only the claims this pulse happened to read.
"""

import calendar
import os
import re
import time

FOREIGN = "same_login_foreign_device"
_ID = r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}"
_ISO = r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"
_CLOCK = re.compile(r"^\[" + _ISO + r"\]")
_LOST = re.compile(r"CLAIM_LOST: runner=(" + _ID + r") lost to (" + _ID + r") on issue \S+ winner_claim_ts=" + _ISO)
_GUARD = re.compile(r"\(cross-runner (?:guard|expired)\): .* runner=(" + _ID + r") device=(" + _ID
                    + r") vs self=(" + _ID + r"),")
_NON_DEVICES = frozenset(("none", "legacy"))
_LIMIT_BYTES = 64 * 1024 * 1024
_LOOKBACK_DEFAULT_S = 7 * 86400


def _epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None


def _recent(epoch, since):
    return epoch is not None and epoch >= since


def _same_login(runner, other, login):
    if runner.lower() != other.lower():
        return False
    return not login or runner.lower() == login


def _lost_is_foreign(match, login, since):
    if not _recent(_epoch(match.group(3)), since):
        return False
    return _same_login(match.group(1), match.group(2), login)


def _guard_is_foreign(match, login, device):
    claimed = match.group(2)
    if not device or claimed == device:
        return False
    if claimed.lower() in _NON_DEVICES:
        return False
    return _same_login(match.group(1), match.group(3), login)


def _line_is_foreign(line, clock, context):
    login, device, since = context
    lost = _LOST.search(line)
    if lost:
        return _lost_is_foreign(lost, login, since)
    guard = _GUARD.search(line)
    if guard is None or not _recent(clock, since):
        return False
    return _guard_is_foreign(guard, login, device)


def classify(text, self_login, device, since):
    """Return FOREIGN for recent positive evidence in text, else `unknown`."""
    context = ((self_login or "").lower(), device, since)
    clock = None
    for line in text.splitlines():
        stamp = _CLOCK.match(line)
        if stamp:
            clock = _epoch(stamp.group(1))
        elif _line_is_foreign(line, clock, context):
            return FOREIGN
    return "unknown"


def _lookback_seconds():
    raw = os.environ.get("AIDEVOPS_QUOTA_FOREIGN_DEVICE_LOOKBACK_S", "").strip()
    return int(raw) if raw.isdigit() and int(raw) > 0 else _LOOKBACK_DEFAULT_S


def _read_tail(path):
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        start = max(0, handle.tell() - _LIMIT_BYTES)
        handle.seek(start)
        raw = handle.read(_LIMIT_BYTES)
    if start:
        # Drop the partial first line so a truncated value is never classified.
        raw = raw[raw.find(b"\n") + 1:] if b"\n" in raw else b""
    return raw.decode("utf-8", errors="replace")


def pulse_log_hint(self_login, device):
    """Classify the tail of the local pulse log without spending API quota."""
    path = (os.environ.get("AIDEVOPS_QUOTA_PULSE_LOG", "").strip()
            or os.path.expanduser("~/.aidevops/logs/pulse.log"))
    try:
        text = _read_tail(path)
    except OSError:
        return "unknown"
    return classify(text, self_login, device, int(time.time()) - _lookback_seconds())
