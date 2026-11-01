# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate saved quota evidence without attributing unknown request costs."""

import re
from collections import defaultdict

AUTH_PATTERN = re.compile(r"[a-f0-9]{64}")


def number(value):
    """Reject oversized or non-ASCII counters without inventing a value."""
    return int(value) if re.fullmatch(r"[0-9]{1,20}", value) else None


def core_attempt(line, start, end):
    """Select only complete legacy prefixes for in-window REST-core attempts."""
    row = line.rstrip("\n").split("\t")
    if len(row) < 17:
        return None
    if row[4] != "rest-core" or row[8] != "attempt":
        return None
    ts = number(row[0])
    if ts is None or not start <= ts <= end:
        return None
    return row, ts


def credential_reset(row):
    """Return a proven series key, not a guessed reset for legacy rows."""
    if len(row) < 22:
        return None
    if not AUTH_PATTERN.fullmatch(row[19]):
        return None
    reset = number(row[20])
    if reset is None or reset <= 0:
        return None
    return row[19], reset


def record_reset_unknown(row, cost, reset_unknown):
    """Keep known costs without a reset beside the credential, not a series."""
    if len(row) >= 20 and AUTH_PATTERN.fullmatch(row[19]):
        reset_unknown[row[19]] += cost or 0


def read_local(path, start, end):
    """Keep credential/reset series independent and duplicate IDs auditable."""
    series = defaultdict(list)
    reset_unknown = defaultdict(int)
    seen = {}
    missing = duplicates = 0
    conflicting = False
    with open(path, encoding="utf-8") as source:
        for line in source:
            parsed = core_attempt(line, start, end)
            if parsed is None:
                continue
            row, ts = parsed
            if row[10] and row[10] != "unknown":
                if row[10] in seen:
                    duplicates += 1
                    conflicting |= seen[row[10]] != row
                    continue
                seen[row[10]] = row
            cost = number(row[16])
            key = credential_reset(row)
            if key is None:
                missing += 1
                record_reset_unknown(row, cost, reset_unknown)
                continue
            series[key].append((ts, number(row[21]), cost))
    return series, reset_unknown, missing, duplicates, conflicting


def ci_sample(sample, start, end):
    """Validate independently known request costs, never shared-counter deltas."""
    if sample.get("event") != "quota-ci-sample":
        return None
    fp = sample["auth_fingerprint"]
    ident = sample["sample_id"]
    if (not isinstance(fp, str) or not isinstance(ident, str)
            or not ident or not AUTH_PATTERN.fullmatch(fp)):
        return None
    before, after = sample["before"], sample["after"]
    before_used, after_used = before["used"], after["used"]
    before_reset, after_reset = before["reset"], after["reset"]
    lo, hi = sample["sample_start"], sample["sample_end"]
    cost = sample["known_api_requests"]
    numbers = (lo, hi, cost, before_used, after_used, before_reset, after_reset)
    if any(type(n) is not int or n < 0 for n in numbers):
        return None
    if (not start <= lo <= hi <= end or before_reset <= 0
            or before_reset != after_reset or not 0 < cost <= after_used - before_used):
        return None
    return (fp, before_reset, ident), (lo, hi, before_used, after_used, cost)
