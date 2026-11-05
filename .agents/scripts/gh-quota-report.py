#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline REST-core attribution for gh-checks-wait-helper.sh quota-report."""

import json
import sys
import time

from gh_quota_evidence import matching_ci, read_ci, read_local


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


def ci_coverage(samples, observed, local_ranges, fingerprint, reset):
    """Credit only CI cost proven additional to possible local overlap."""
    if not observed:
        return None
    first = min(row[0] for row in observed)
    last = max(row[0] for row in observed)
    lower = min(row[1] for row in observed)
    upper = max(row[1] for row in observed)
    bounds = (first, last, lower, upper)
    ci_cost = None
    ci_ranges = []
    for value, decision in sorted(samples, key=lambda item: item[0]):
        result = dict(auth_fingerprint=fingerprint, reset_epoch=reset,
                      reason="outside_observed_interval", credited_cost=0)
        decision.setdefault("series", []).append(result)
        decision["reason"] = "evaluated"
        credited = credit_sample(value, bounds, local_ranges, ci_ranges, result)
        if credited is not None:
            ci_cost = (ci_cost or 0) + credited
    return ci_cost


def credit_sample(value, bounds, local_ranges, ci_ranges, result):
    """Return credited cost for one sample, or None when it is not creditable."""
    lo, hi, before, after, cost = value
    first, last, lower, upper = bounds
    if not (first <= lo <= hi <= last and lower <= before < after <= upper):
        return None
    # Overlapping audit intervals cannot prove independent spend twice.
    if any(before < right and after > left for left, right in ci_ranges):
        result["reason"] = "overlapping_ci"
        return None
    ci_ranges.append((before, after))
    local_overlap = sum(max(0, min(after, right) - max(before, left))
                        for left, right in local_ranges)
    # Subtract overlap from known cost, not merely from interval capacity:
    # the probe itself might already be present in the local attempt log.
    credited = max(cost - local_overlap, 0)
    result.update(reason="credited" if credited else "locally_covered",
                  credited_cost=credited)
    return credited


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
        ci_samples, identities, decisions = read_ci(sys.argv[3], start, end)
    except OSError:
        print("quota-report: CI evidence log unavailable", file=sys.stderr)
        return 2
    for (fingerprint, reset), rows in sorted(series.items()):
        observed, local_ranges, metrics = local_coverage(rows)
        samples = matching_ci(ci_samples, identities, fingerprint, reset)
        ci_cost = ci_coverage(samples, observed, local_ranges, fingerprint, reset)
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
    for decision in decisions:
        print(json.dumps(decision, sort_keys=True), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
