# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate saved CI quota rows before recording or matching evidence."""

import re

AUTH_PATTERN = re.compile(r"[a-f0-9]{64}")


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


def ci_identity(sample):
    """Require explicit host and quota pool; a matching reset is not identity."""
    fp = sample.get("auth_fingerprint", "")
    fields = [sample.get(name) for name in ("host", "login", "pool")]
    if not isinstance(fp, str) or not AUTH_PATTERN.fullmatch(fp):
        raise ValueError("invalid identity fingerprint")
    if any(not isinstance(value, str) or not value for value in fields):
        raise ValueError("missing identity fields")
    host, login, pool = fields
    if not re.fullmatch(r"[a-zA-Z0-9.-]+", host) or pool != "rest-core":
        raise ValueError("invalid identity scope")
    if not re.fullmatch(r"[a-zA-Z0-9-]+", login):
        raise ValueError("invalid login")
    return fp, (host.lower(), login.lower(), pool)


def parse_ci_row(sample, start, end):
    """Return a reason code without returning any unvalidated input text."""
    if not isinstance(sample, dict):
        return None, "invalid_sample"
    if sample.get("event") != "quota-ci-sample":
        return None, "unsupported_event"
    parsed = ci_sample(sample, 0, 10**20)
    if parsed is None:
        return None, "invalid_sample"
    if not start <= parsed[1][0] <= parsed[1][1] <= end:
        return parsed, "outside_window"
    return parsed, "unmatched_identity_or_reset"


def keep_ci_sample(samples, parsed, decision):
    """Invalidate all copies of conflicting IDs, including earlier copies."""
    key, value = parsed
    if key not in samples:
        samples[key] = (value, [decision])
        return
    previous, copies = samples[key]
    decision["reason"] = "duplicate"
    if previous != value or copies[0]["reason"] == "conflicting_id":
        for copy in copies + [decision]:
            copy["reason"] = "conflicting_id"
    copies.append(decision)
