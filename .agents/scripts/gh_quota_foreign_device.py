#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline same-login foreign-device hint for REST quota reports.

Reads saved DISPATCH_CLAIM comment text (never fetched here: reporting must not
spend the quota being measured). Without a definite answer from that file, it
falls back to positive evidence the local pulse already logged while reading
claims (GH#37888): `CLAIM_LOST ... lost to <self>` (only another device of the
same login can win that race) and cross-runner guard lines whose `runner=` is
`self=` but whose `device=` is not local. Pulse-log evidence older than the
lookback (default 7 days) is ignored, and its absence never yields `none`.
Prints one token:

  same_login_foreign_device  a claim for the self login names another device
  none                       claims were readable and show only the local device
  unknown                    no evidence file, self login or local device id

Usage: gh_quota_foreign_device.py CLAIMS_FILE SELF_LOGIN [DEVICE_ID_FILE]
Environment: AIDEVOPS_QUOTA_PULSE_LOG (default ~/.aidevops/logs/pulse.log),
AIDEVOPS_QUOTA_FOREIGN_DEVICE_LOOKBACK_S (default 604800).
"""

import calendar
import os
import re
import sys
import time

_ID = r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}"
_RUNNER = re.compile(r"(?:^|\s)runner=(" + _ID + r")(?=\s|$)")
_DEVICE = re.compile(r"(?:^|\s)device=(" + _ID + r")(?=\s|$)")
_ISO = r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"
_CLOCK = re.compile(r"^\[" + _ISO + r"\]")
# dispatch-claim-helper.sh: a same-runner winner on this device is CLAIM_STALE_SELF,
# so a same-runner CLAIM_LOST proves a non-legacy claim from another device.
_LOST = re.compile(r"CLAIM_LOST: runner=(" + _ID + r") lost to (" + _ID + r") on issue \S+ winner_claim_ts=" + _ISO)
# pulse-issue-reconcile-stale.sh cross-runner guard/expiry lines.
_GUARD = re.compile(r"\(cross-runner (?:guard|expired)\): .* runner=(" + _ID + r") device=(" + _ID
                    + r") vs self=(" + _ID + r"),")
_NON_DEVICES = frozenset(("none", "legacy"))
_PULSE_LOG_LIMIT_BYTES = 64 * 1024 * 1024
_LOOKBACK_DEFAULT_S = 7 * 86400


def local_device(path):
    override = os.environ.get("AIDEVOPS_DEVICE_ID", "").strip()
    if override:
        return override
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except (OSError, UnicodeError):
        return ""


def classify(text, self_login, device):
    """Return the hint token for DISPATCH_CLAIM lines in text."""
    if not (text and self_login and device):
        return "unknown"
    seen = False
    for line in text.splitlines():
        if "DISPATCH_CLAIM" not in line:
            continue
        runner, claimed = _RUNNER.search(line), _DEVICE.search(line)
        if not runner or not claimed or runner.group(1).lower() != self_login.lower():
            continue
        seen = True
        if claimed.group(1) != device:
            return "same_login_foreign_device"
    return "none" if seen else "unknown"


_EVIDENCE_LIMIT_BYTES = 4 * 1024 * 1024


def _epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None


def classify_pulse_log(text, self_login, device, since):
    """Return `same_login_foreign_device` for recent positive log evidence, else `unknown`."""
    login = (self_login or "").lower()
    clock = None
    for line in text.splitlines():
        stamp = _CLOCK.match(line)
        if stamp:
            clock = _epoch(stamp.group(1))
            continue
        lost = _LOST.search(line)
        if lost:
            runner, winner, at = lost.group(1).lower(), lost.group(2).lower(), _epoch(lost.group(3))
            if runner == winner and (not login or runner == login) and at is not None and at >= since:
                return "same_login_foreign_device"
            continue
        guard = _GUARD.search(line)
        if not guard or clock is None or clock < since:
            continue
        runner, claimed, owner = guard.group(1).lower(), guard.group(2), guard.group(3).lower()
        if (runner == owner and (not login or runner == login) and device
                and claimed != device and claimed.lower() not in _NON_DEVICES):
            return "same_login_foreign_device"
    return "unknown"


def _lookback_seconds():
    raw = os.environ.get("AIDEVOPS_QUOTA_FOREIGN_DEVICE_LOOKBACK_S", "").strip()
    return int(raw) if raw.isdigit() and int(raw) > 0 else _LOOKBACK_DEFAULT_S


def pulse_log_hint(self_login, device):
    """Classify the tail of the local pulse log without spending API quota."""
    path = (os.environ.get("AIDEVOPS_QUOTA_PULSE_LOG", "").strip()
            or os.path.expanduser("~/.aidevops/logs/pulse.log"))
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            start = max(0, size - _PULSE_LOG_LIMIT_BYTES)
            handle.seek(start)
            raw = handle.read(_PULSE_LOG_LIMIT_BYTES)
    except OSError:
        return "unknown"
    if start:
        # Drop the partial first line so a truncated value is never classified.
        raw = raw[raw.find(b"\n") + 1:] if b"\n" in raw else b""
    since = int(time.time()) - _lookback_seconds()
    return classify_pulse_log(raw.decode("utf-8", errors="replace"), self_login, device, since)


def _explicit_hint(claims_file, self_login, device):
    if not claims_file or not self_login:
        return "unknown"
    try:
        with open(claims_file, "rb") as handle:
            raw = handle.read(_EVIDENCE_LIMIT_BYTES + 1)
    except OSError:
        return "unknown"
    # Do not classify incomplete evidence or a device value split at the limit;
    # the limit is in bytes, so multi-byte UTF-8 cannot slip past it.
    if len(raw) > _EVIDENCE_LIMIT_BYTES:
        return "unknown"
    return classify(raw.decode("utf-8", errors="replace"), self_login, device)


def hint(claims_file, self_login, device_file=""):
    """Return the hint token; positive evidence from either source wins over `none`."""
    # Same precedence as dispatch-claim-helper.sh, which writes the claim device.
    device_path = (device_file or os.environ.get("AIDEVOPS_DEVICE_ID_FILE", "").strip()
                   or os.path.expanduser("~/.aidevops/state/device-id"))
    device = local_device(device_path)
    explicit = _explicit_hint(claims_file, self_login, device)
    if explicit == "same_login_foreign_device":
        return explicit
    logged = pulse_log_hint(self_login, device)
    return logged if logged == "same_login_foreign_device" else explicit


def main(argv):
    print(hint(*(argv[1:4] + [""] * (3 - len(argv[1:4])))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
