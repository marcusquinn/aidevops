<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GitHub API efficiency benchmark

The GitHub API efficiency benchmark compares two immutable, privacy-safe
observation windows. It proves request savings only when transport, workload,
latency, freshness, correctness, and path-budget evidence are all complete and
comparable.

The benchmark never reads raw API telemetry and never changes runtime defaults.
An inconclusive result preserves every rollback control and keeps the rollout
task open.

## Command

```bash
.agents/scripts/github-api-efficiency-benchmark.sh compare \
  --baseline-report "${BASELINE_REPORT}" \
  --baseline-evidence "${BASELINE_EVIDENCE}" \
  --baseline-label "baseline-before-change" \
  --canary-report "${CANARY_REPORT}" \
  --canary-evidence "${CANARY_EVIDENCE}" \
  --canary-label "canary-after-change" \
  --canary-not-before "${ROLLOUT_EPOCH}" \
  --json-out "${RESULT_JSON}" \
  --markdown-out "${RESULT_MARKDOWN}"
```

`--canary-not-before` is required. It is the UTC epoch at which the measured
rollout became active, not the time at which the report was generated.

Exit codes:

| Code | Status | Meaning |
|---:|---|---|
| `0` | `PASS` | Comparable evidence meets every savings and guardrail threshold. |
| `1` | `REGRESSION` | Comparable evidence breaches one or more thresholds. |
| `2` | `INCONCLUSIVE` | Inputs are invalid, incomplete, unknown, or noncomparable. |

JSON output uses `aidevops-github-api-efficiency-benchmark/v1`. Each output file
is written through a private temporary file and atomically renamed. Re-running
with identical inputs and options is byte-stable.

## Input contract

### Transport aggregate

Each transport input must be an immutable JSON report produced by
`.agents/scripts/gh-api-aggregate.awk` with `_meta.schema_version == 2`.
The benchmark validates:

- first and last retained attempt timestamps and their effective duration;
- exact attempt accounting and path reconciliation;
- quota-cost reconciliation;
- malformed, legacy, unidentified, duplicate, opaque-pagination, and unknown
  attempt counters;
- the supported path set: `graphql`, `rest`, `search-graphql`, `search-rest`,
  `other`, and `unknown`.

Any unknown quota cost or unclassified transport attempt prevents `PASS`.
Never derive a benchmark by reading the raw JSONL/log source directly.

### Evidence sidecar

Each transport aggregate has one sidecar using
`aidevops-github-api-efficiency-evidence/v1`. `transport_sha256` binds the
sidecar to the exact aggregate bytes. The result also records the sidecar's own
SHA-256 digest.

The Pulse wrapper now publishes this sidecar automatically after each real cycle.
It writes the transport aggregate first, binds the sidecar to those exact bytes,
and atomically replaces both private files with mode `600`. Defaults are
`~/.aidevops/logs/gh-api-calls-by-stage.json` and
`~/.aidevops/logs/gh-api-efficiency-evidence.json`; override them with
`AIDEVOPS_GH_API_REPORT` and `AIDEVOPS_GH_API_EVIDENCE`. Set
`AIDEVOPS_GH_API_EVIDENCE_DISABLE=1` to disable sidecar production without
disabling transport telemetry. Invalid or insufficient retained windows remove a
stale sidecar instead of preserving misleading evidence.

Coverage contract `1` starts at a private persisted activation timestamp and is
re-emitted each cycle so a rolling window becomes bounded only after every
retained attempt post-dates instrumentation activation. Population, latency,
cache, single-flight, and path-budget ownership currently emit complete coverage
markers. Webhook and guardrail events are collected, but those groups deliberately
remain uncovered—and therefore `null`—until duplicate-action, recovery,
stale-positive, and dispatch-dependency semantics have complete production
ownership. Never promote absent events in an uncovered group to observed zero.

The following is an intentionally incomplete template. Replace every required
`null` with a privacy-safe observed value and set `complete` to `true` only when
the whole fixed window has been reconciled. The transport digest must be 64
lowercase hexadecimal characters.

```json
{
  "schema": "aidevops-github-api-efficiency-evidence/v1",
  "transport_sha256": "<sha256-of-exact-transport-report>",
  "complete": false,
  "population": {
    "repository_count": null,
    "pulse_cycles": null,
    "unchanged_cycles": null,
    "actionable_changes": null,
    "unique_actionable_head_shas": null,
    "repository_set_sha256": null
  },
  "latency": {
    "p50_ms": null,
    "p95_ms": null,
    "peak_attempts_per_minute": null,
    "completed_action_p95_ms": null
  },
  "cache": {
    "fresh_hits": null,
    "fresh_empty_hits": null,
    "misses": null,
    "stale": null,
    "invalidated": null
  },
  "single_flight": {
    "leaders": null,
    "waits": null,
    "takeovers": null,
    "duplicate_leaders": null
  },
  "webhook": {
    "invalidations": null,
    "lag_p50_ms": null,
    "lag_p95_ms": null,
    "duplicate_actions": null,
    "missed_recoveries": null
  },
  "guardrails": {
    "stale_snapshot_detections": null,
    "forced_live_refreshes": null,
    "stale_positive_decisions": null,
    "dispatch_dependency_violations": null,
    "required_check_merge_preflight_mismatches": null
  },
  "path_budgets": {
    "fingerprint_verification_list_calls": null,
    "fresh_empty_live_fallbacks": null,
    "aggregate_check_fetches": null
  }
}
```

Evidence values are non-negative JSON-safe numbers. Counts should remain
integers. Repository identity is represented only by the SHA-256 digest of the
sorted fixed repository set; do not put repository names, request payloads,
tokens, URLs, or raw log records in the sidecar.

### Evidence ownership

| Group | Privacy-safe source |
|---|---|
| `population` | Fixed Pulse scope and cycle/outcome counters for the retained window. |
| `latency` | Aggregate request and completed-action histograms plus peak minute count. |
| `cache` | Canonical snapshot/check-cache decision counters. |
| `single_flight` | Leader, follower wait, takeover, and duplicate-leader counters. |
| `webhook` | `pulse-merge-webhook-server.py` emits a protocol-v1 millisecond receive marker; `pulse-merge-webhook-receiver.sh` records successful invalidations, delivery-to-invalidation lag, and invalidations delegated to polling recovery. |
| `guardrails` | Snapshot/check-cache freshness detections, forced live refreshes, and live required-check preflight mismatches. Unsupported stale-positive and dispatch-dependency fields remain unknown. |
| `path_budgets` | Deterministic call-site counters from focused request-budget tests/telemetry. |

## Comparability gate

The benchmark evaluates regressions only after both windows pass all
completeness checks. It otherwise returns `INCONCLUSIVE`.

Default comparability rules:

- same repository count and repository-set digest;
- non-overlapping retained attempt windows;
- canary starts on or after `--canary-not-before`;
- larger effective duration divided by smaller duration is at most `1.25`;
- Pulse cycle-rate change is at most `25%`;
- unchanged-cycle, actionable-change, and unique-actionable-head rates each
  change by at most `25%`;
- both reports contain exact attempts, zero unknown quota attempts, zero legacy
  or malformed records, and no unclassified transport attempts;
- every sidecar field is known and both sidecars are marked complete;
- both windows contain at least one repository, Pulse cycle, and transport
  attempt.

## Metrics and decision thresholds

The JSON and Markdown reports include absolute and normalized transport values
per repository-hour, Pulse cycle, unchanged cycle, actionable change, and
unique actionable head SHA where the denominator is non-zero.

Transport metrics are attempts, GraphQL points, GraphQL attempts, REST
attempts, search attempts, unclassified attempts, retries, pages, additional
pages, and API errors. `search_attempts` includes both GraphQL and REST search;
it is intentionally a cross-cutting category rather than a partition of total
attempts.

Default `PASS` thresholds:

| Decision | Default |
|---|---:|
| Attempt reduction per repository-hour | at least `5%` |
| Attempt reduction per Pulse cycle | at least `5%` |
| GraphQL-point increase per repository-hour | at most `0%` |
| GraphQL-point increase per Pulse cycle | at most `0%` |
| API error-rate increase | at most `0` percentage points |
| Request/completed-action p95 increase | at most `20%` |
| Webhook invalidation p95 lag increase | at most `20%` |
| Peak attempts-per-minute increase | at most `10%` |

The canary must also have:

- zero stale-positive decisions, dispatch dependency violations, and
  required-check/merge-preflight mismatches;
- zero duplicate single-flight leaders, duplicate webhook actions, and missed
  webhook recoveries;
- zero fingerprint/verification list calls and fresh-empty live fallbacks;
- no more than one aggregate check fetch per unique actionable head SHA.

Threshold options may make a comparison stricter. Any deliberate relaxation
requires issue/PR rationale and another canary; do not weaken a threshold merely
to convert an observed regression into a pass.

## Observation workflow

1. Define a fixed repository population and record its sorted-set SHA-256.
2. Record the exact rollout epoch.
3. Copy the completed aggregate to an immutable regular file. Do not benchmark
   a report that is still being replaced by an active aggregation job.
4. Reconcile the complete sidecar from privacy-safe aggregate counters.
5. Collect a non-overlapping canary with a similar retained duration and Pulse
   cycle rate.
6. Run the benchmark and attach both generated reports to the rollout task.
7. On `INCONCLUSIVE`, collect missing evidence without tuning or removing
   controls. On `REGRESSION`, restore the owning bounded default and repeat the
   same focused tests. On `PASS`, change at most one bounded default/control at
   a time and repeat the canary.

## Current t18131 checkpoint

The retained generation-8 baseline ends at `2026-07-18T06:04:10Z`. Its quota
cost is unknown for all retained attempts. The later aggregate begins before
t18130 merged at `2026-07-18T15:49:27Z` (`1784389767`) and also contains unknown
quota costs. Neither report can produce `PASS`.

Therefore this implementation does not tune `.agents/configs/pulse-sweep-budget.json`,
does not tune `.agents/configs/webhook-receiver.conf`, and removes no feature or
rollback flag. A valid final comparison requires both a new exact baseline and
a 12–24 hour post-rollout canary with complete sidecars.

## Retained controls and rollback triggers

Owner for the following controls is the aidevops Pulse maintainers. Review them
after the first valid t18131 canary, no earlier than `2026-07-20`. A review date
is not an automatic expiry: unknown evidence retains the control.

| Control/default | Why retained | Rollback trigger and compatibility decision |
|---|---|---|
| `state_fingerprint_cache_hit_enabled=true` | Existing baseline is not quota-exact, so the canonical-snapshot saving is not yet proven system-wide. | Set `false` if snapshot cache hits cause stale-positive or dependency/preflight mismatches; keep the reader compatible until a valid canary passes. |
| `PULSE_BATCH_PREFETCH_ENABLED=1` | Primary bounded batch path remains covered by focused tests but needs real aggregate proof. | Set `0` for freshness/correctness regression; preserve the non-batch path. |
| `PULSE_BATCH_CONDITIONAL_REST_ENABLED=1` | ETag refresh is bounded and falls back, but incomplete or invalidated snapshots must not be reused. | Set `0` if fresh-empty fallback, stale publication, or conditional-response validation regresses. |
| `PULSE_BATCH_SEARCH_LAST_RESORT=1` | Owner search currently routes through REST/cache before GraphQL. | Set `0` if REST/search error or secondary-limit evidence regresses; retain the GraphQL fallback. |
| Snapshot schema `aidevops-pulse-snapshot/v1` | Auth scope, projection, completeness, generation, and invalidation generation fence mixed state. | Reject incompatible/legacy snapshots and live-refresh; do not remove compatibility handling before fleet convergence. |
| Check cache enabled; terminal TTL `21600s`, actionable TTL `30s` | Exact-head terminal state is immutable, while actionable state remains short-lived. | Set `AIDEVOPS_GH_CHECK_STATUS_CACHE_DISABLE=1` for stale state; retain TTL caps (`604800s` terminal, `300s` actionable). |
| Shared request state enabled; lease `30s`, wait `10s`, outcome TTL `10s`, rate TTL `20s` | Single-flight and scoped rate snapshots reduce duplicate reads with bounded takeover. | Set `AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1` or `AIDEVOPS_GH_REQUEST_STATE_DISABLE=1` for duplicate leaders, stuck waits, or publication-fencing defects. |
| Webhook protocol `v1`; loopback listener; ledger TTL `604800s`; maximum `4096`; dispatch concurrency `4` | Verified invalidation accelerates freshness while the periodic polling backstop remains authoritative. | Disable the receiver service for authentication, replay, lag, duplicate-action, or missed-recovery regression; keep polling and protocol-v1 validation. |

Secure loopback binding, webhook signature verification, request-size bounds, and
the periodic polling backstop are safety controls, not optimization flags, and
must not be removed by an efficiency-only canary.

## Verification

```bash
bash .agents/scripts/tests/test-gh-api-instrument.sh
bash .agents/scripts/tests/test-gh-request-singleflight.sh
bash .agents/scripts/tests/test-gh-check-status-cache.sh
bash .agents/scripts/tests/test-pulse-wrapper-cycle-gates.sh
bash .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh
python3 .agents/scripts/tests/test-pulse-merge-webhook-invalidation.py
bash .agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh
bash .agents/scripts/tests/test-github-api-efficiency-evidence.sh
bash .agents/scripts/tests/test-github-api-efficiency-benchmark.sh
shellcheck \
  .agents/scripts/gh-api-instrument.sh \
  .agents/scripts/pulse-wrapper-cycle-gates.sh \
  .agents/scripts/pulse-batch-prefetch-helper.sh \
  .agents/scripts/pulse-merge-webhook-receiver.sh \
  .agents/scripts/github-api-efficiency-benchmark.sh \
  .agents/scripts/tests/test-github-api-efficiency-benchmark.sh
python3 -m py_compile \
  .agents/scripts/github-api-efficiency-evidence.py \
  .agents/scripts/github-api-efficiency-benchmark.py \
  .agents/scripts/github_api_efficiency_events.py \
  .agents/scripts/github_api_efficiency_inputs.py \
  .agents/scripts/github_api_efficiency_metrics.py \
  .agents/scripts/github_api_efficiency_report.py \
  .agents/scripts/pulse-merge-webhook-server.py
```

The fixture suite covers deterministic pass output, regressions, incomplete
evidence, materially unequal windows, rollout boundaries, unknown quota costs,
non-equivalent workload mixes, unclassified attempts, inconsistent counters or
population relationships, incompatible schemas, and mismatched evidence digests.
