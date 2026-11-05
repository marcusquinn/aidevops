# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate saved quota evidence without attributing unknown request costs."""

import json
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
        return None, "outside_window"
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


def read_ci(path, start, end):
    """Keep a decision for every input row, never echoing raw saved evidence."""
    samples, identities, decisions = {}, {}, []
    if not path:
        return samples, identities, decisions
    with open(path, encoding="utf-8") as source:
        for index, line in enumerate(source, 1):
            decision = dict(event="quota-ci-decision", input_line=index,
                            reason="invalid_sample")
            decisions.append(decision)
            try:
                read_ci_row(line, start, end, samples, identities, decision)
            except (ValueError, TypeError, KeyError, AttributeError, RecursionError):
                continue
    return samples, identities, decisions


def record_identity(identities, sample):
    """Store one saved identity; a conflict stays invalid regardless of order."""
    fp, identity = ci_identity(sample)
    if fp in identities and identities[fp] != identity:
        identity = None
    identities[fp] = identity


def read_ci_row(line, start, end, samples, identities, decision):
    """Classify one saved row, recording only a reason code."""
    sample = json.loads(line)
    if isinstance(sample, dict) and sample.get("event") == "quota-ci-identity":
        record_identity(identities, sample)
        decision["reason"] = "identity_record"
        return
    parsed, decision["reason"] = parse_ci_row(sample, start, end)
    if parsed is not None:
        keep_ci_sample(samples, parsed, decision)


def matching_ci(samples, identities, fingerprint, reset):
    """Join tokens only with an unambiguous saved host/login/pool mapping."""
    identity = identities.get(fingerprint)
    matched = []
    for (fp, sample_reset, _), (value, copies) in samples.items():
        if sample_reset != reset or copies[0]["reason"] == "conflicting_id":
            continue
        if fp == fingerprint or (identity is not None and identities.get(fp) == identity):
            matched.append((value, copies[0]))
    return matched
