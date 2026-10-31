#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline REST-core attribution for gh-checks-wait-helper.sh quota-report."""

import json
import re
import sys
import time
from collections import defaultdict

AUTH_PATTERN = re.compile(r"[a-f0-9]{64}")


def number(value):
    """Reject oversized or non-ASCII counters without inventing a value."""
    return int(value) if re.fullmatch(r"[0-9]{1,20}", value) else None


def read_local(path, start, end):
    """Keep credential/reset series independent and duplicate IDs auditable."""
    series = defaultdict(list)
    reset_unknown = defaultdict(int)
    seen = {}
    missing = duplicates = 0
    conflicting = False
    with open(path, encoding="utf-8") as source:
        for line in source:
            row = line.rstrip("\n").split("\t")
            if len(row) < 17:
                continue
            ts = number(row[0])
            if (ts is None or not start <= ts <= end
                    or row[4] != "rest-core" or row[8] != "attempt"):
                continue
            if row[10] and row[10] != "unknown":
                if row[10] in seen:
                    duplicates += 1
                    conflicting |= seen[row[10]] != row
                    continue
                seen[row[10]] = row
            cost = number(row[16])
            reset = number(row[20]) if len(row) >= 21 else None
            if (len(row) < 22 or not AUTH_PATTERN.fullmatch(row[19])
                    or reset is None or reset <= 0):
                missing += 1
                if len(row) >= 20 and AUTH_PATTERN.fullmatch(row[19]):
                    reset_unknown[row[19]] += cost or 0
                continue
            series[(row[19], reset)].append((ts, number(row[21]), cost))
    return series, reset_unknown, missing, duplicates, conflicting


def ci_sample(sample, start, end):
    """Validate independently known request costs, never shared-counter deltas."""
    if sample.get("event") != "quota-ci-sample":
        return None
    fp = sample["auth_fingerprint"]
    before, after = sample["before"], sample["after"]
    before_used, after_used = before["used"], after["used"]
    before_reset, after_reset = before["reset"], after["reset"]
    lo, hi = sample["sample_start"], sample["sample_end"]
    cost, ident = sample["known_api_requests"], sample["sample_id"]
    numbers = (lo, hi, cost, before_used, after_used, before_reset, after_reset)
    if (not isinstance(fp, str) or not AUTH_PATTERN.fullmatch(fp)
            or not isinstance(ident, str) or not ident
            or any(type(n) is not int or n < 0 for n in numbers)
            or not start <= lo <= hi <= end or before_reset <= 0
            or before_reset != after_reset
            or not 0 < cost <= after_used - before_used):
        return None
    return (fp, before_reset, ident), (lo, hi, before_used, after_used, cost)


def read_ci(path, start, end):
    """Read operator-saved audit JSONL, rejecting conflicting sample IDs."""
    series = defaultdict(list)
    if not path:
        return series
    samples = {}
    conflicted = set()
    with open(path, encoding="utf-8") as source:
        for line in source:
            try:
                parsed = ci_sample(json.loads(line), start, end)
                if parsed is None:
                    continue
                key, value = parsed
                if key in samples and samples[key] != value:
                    conflicted.add(key)
                samples[key] = value
            except (ValueError, TypeError, KeyError, AttributeError, RecursionError):
                continue
    for key, value in samples.items():
        if key not in conflicted:
            series[key[:2]].append(value)
    return series


def local_coverage(rows):
    """Order counters, not late command completions; count each range once."""
    observed = sorted((row for row in rows if row[1] is not None),
                      key=lambda row: (row[0], row[1]))
    regressions = sum(b[1] < a[1] for a, b in zip(observed, observed[1:]))
    previous = None
    used_delta = known = unknown = intervals = 0
    local_ranges = []
    # A cumulative counter is a stronger ordering key than command completion.
    # This ordering is valid only inside one credential/reset series.
    for _, used, cost in sorted(rows, key=lambda row: (row[1] if row[1] is not None else -1, row[0])):
        if cost is None:
            unknown += 1
        if used is None:
            if cost is not None:
                unknown += 1
            continue
        if previous is not None:
            delta = used - previous
            intervals += 1
            used_delta += delta
            if cost is not None:
                credited = min(cost, delta)
                known += credited
                local_ranges.append((used - credited, used))
        previous = used
    metrics = dict(used_delta=used_delta, known_local_cost=known,
                   unknown_cost_attempts=unknown, counter_regressions=regressions,
                   intervals=intervals)
    return observed, local_ranges, metrics


def ci_coverage(samples, observed, local_ranges):
    """Credit only CI cost proven additional to possible local overlap."""
    if not observed:
        return None
    first = min(row[0] for row in observed)
    last = max(row[0] for row in observed)
    lower = min(row[1] for row in observed)
    upper = max(row[1] for row in observed)
    ci_cost = None
    ci_ranges = []
    for lo, hi, before, after, cost in sorted(samples):
        if not (first <= lo <= hi <= last and lower <= before < after <= upper):
            continue
        # Overlapping audit intervals cannot prove independent spend twice.
        if any(before < right and after > left for left, right in ci_ranges):
            continue
        ci_ranges.append((before, after))
        local_overlap = sum(max(0, min(after, right) - max(before, left))
                            for left, right in local_ranges)
        # Subtract overlap from known cost, not merely from interval capacity:
        # the probe itself might already be present in the local attempt log.
        ci_cost = (ci_cost or 0) + max(cost - local_overlap, 0)
    return ci_cost


def main():
    """Emit the existing quota-unattributed schema without network activity."""
    end = int(time.time())
    start = end - int(sys.argv[2])
    try:
        series, reset_unknown, missing, duplicates, conflicting = read_local(sys.argv[1], start, end)
    except OSError:
        print("quota-report: local API log unavailable", file=sys.stderr)
        return 2
    try:
        ci_series = read_ci(sys.argv[3], start, end)
    except OSError:
        print("quota-report: CI evidence log unavailable", file=sys.stderr)
        return 2
    for (fingerprint, reset), rows in sorted(series.items()):
        observed, local_ranges, metrics = local_coverage(rows)
        ci_cost = ci_coverage(ci_series[(fingerprint, reset)], observed, local_ranges)
        used_delta, known = metrics["used_delta"], metrics["known_local_cost"]
        uncertain = metrics["unknown_cost_attempts"] or missing or conflicting
        report = dict(
            event="quota-unattributed", pool="rest-core", auth_fingerprint=fingerprint,
            reset_epoch=reset, window_start=start, window_end=end,
            sample_start=min((row[0] for row in observed), default=None),
            sample_end=max((row[0] for row in observed), default=None),
            unattributed_cost=used_delta - known - (ci_cost or 0),
            accounted_fraction=((known + (ci_cost or 0)) / used_delta
                                if used_delta and not uncertain else None),
            unattributed_is_upper_bound=True, attributed_ci_cost=ci_cost,
            same_login_external_cost=used_delta - known, other_devices="unknown",
            same_credential_reset_unknown_cost=reset_unknown[fingerprint],
            duplicate_attempt_ids=duplicates, missing_metadata_attempts=missing,
        )
        report.update(metrics)
        print(json.dumps(report, sort_keys=True))
    if not series:
        print(json.dumps(dict(event="quota-unattributed", status="insufficient-samples",
                              missing_metadata_attempts=missing)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
