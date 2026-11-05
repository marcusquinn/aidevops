# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate saved quota evidence without attributing unknown request costs."""

import json
import re
from collections import defaultdict

from gh_quota_ci_rows import AUTH_PATTERN, ci_identity, keep_ci_sample, parse_ci_row


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


def read_ci(path, start, end):
    """Keep a decision for every input row, never echoing raw saved evidence."""
    samples, identities, decisions = {}, {}, []
    if not path:
        return samples, identities, decisions
    with open(path, "rb") as source:
        for index, line in enumerate(source, 1):
            decision = dict(event="quota-ci-decision", input_line=index,
                            reason="invalid_sample")
            decisions.append(decision)
            try:
                sample = json.loads(line.decode("utf-8"))
                if isinstance(sample, dict) and sample.get("event") == "quota-ci-identity":
                    record_identity(identities, sample)
                    decision["reason"] = "identity_record"
                    continue
                parsed, decision["reason"] = parse_ci_row(sample, start, end)
                if parsed is not None:
                    keep_ci_sample(samples, parsed, decision)
            except (ValueError, TypeError, KeyError, AttributeError, RecursionError):
                continue
    return samples, identities, decisions


def record_identity(identities, sample):
    """Store one saved identity; a conflict stays invalid regardless of order."""
    fp, identity = ci_identity(sample)
    if fp in identities and identities[fp] != identity:
        identity = None
    identities[fp] = identity


def matching_ci(samples, identities, fingerprint, reset):
    """Join tokens only with an unambiguous saved host/login/pool mapping."""
    identity = identities.get(fingerprint)
    matched = []
    for (fp, sample_reset, _), (value, copies) in samples.items():
        if (sample_reset != reset
                or copies[0]["reason"] in ("conflicting_id", "outside_window")):
            continue
        if fp == fingerprint or (identity is not None and identities.get(fp) == identity):
            matched.append((value, copies[0]))
    return matched
