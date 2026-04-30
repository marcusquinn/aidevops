<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Stuck-merge detector and zero-progress circuit breaker (t3193, GH#21895)

The pulse merge pass historically had two narrow nudges (rebase reminders for
`origin:interactive` PRs in conflict, fix-worker dispatch for `origin:worker`
PRs in conflict) but no general detector for PRs that pass `APPROVED +
MERGEABLE` yet sit unmerged for hours. The 2026-04-30 incident in a managed
private webapp repo — 8 PRs stuck 9-29h, six sharing identical Setup-step CI
failures — is the canonical case this module addresses.

## What it does

Once per pulse cycle (~120s), per repo, after the deterministic merge pass:

1. **Classifies** every open PR that is `APPROVED + MERGEABLE + !draft +
   !hold-for-review` and idle past `AIDEVOPS_MERGE_STUCK_AGE_MINUTES` (default
   240 = 4h) into one of six classes — see "Classifications" below.
2. **Counts** stuck PRs into the `pulse_merge_eligible_stuck_pr_count` gauge.
3. **Escalates per-PR** with a single worker-ready comment on the linked
   issue (or PR if no linked issue), keyed off the
   `<!-- merge-stuck:individual -->` HTML marker so repeat cycles do not spam.
4. **Detects pattern outages** — when ≥`AIDEVOPS_MERGE_PATTERN_MIN_PRS` (default
   3) PRs share the same failure fingerprint (sorted set of FAILURE check
   names, hashed to 16 hex chars), files **one** investigation meta-issue per
   fingerprint dedup'd by `<!-- merge-stuck:pattern:<hash16> -->`.
5. **Tracks zero-progress** across all repos. If a cycle has eligible-but-
   unmerged PRs and zero merges, the `pulse_merge_zero_progress_cycles` gauge
   increments. Reaching `AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES` (default 5
   consecutive cycles ≈ 10 minutes) files a framework-level meta-issue at
   `marcusquinn/aidevops` dedup'd by `<!-- merge-stuck:zero-progress -->`.
   A successful merge in any subsequent cycle resets the gauge to 0.

## Classifications

| Class | Trigger | Action |
| --- | --- | --- |
| `STUCK_CHECKS_FAILING` | ≥1 FAILURE in `statusCheckRollup`, no conflict | Per-PR escalation |
| `STUCK_CONFLICT_NO_NUDGE_LABEL` | `mergeable=CONFLICTING` + neither `origin:interactive` nor `origin:worker` (gap in the existing rebase-nudge family) | Idempotent rebase nudge using `<!-- pulse-rebase-nudge -->` so it cannot double-fire alongside the per-label nudges |
| `STUCK_BRANCHPROTECT_404` | Default branch has no protection rules — `_check_required_checks_passing` historically failed closed (t2922) on the 404 | Counter increment only; the actual fix is in `pulse-merge-process.sh` (see "404 distinction" below) |
| `STUCK_BRANCHPROTECT_API_ERROR` | 5xx / network from the protection API | Counter increment only — transient, retry next cycle |
| `STUCK_AUTH` | 401 / "bad credentials" from any `gh` call | Counter increment only — operator action required |
| `STUCK_OTHER` | Eligible + idle but no distinct signal | Counter increment only |

## Configuration

Canonical defaults live in `.agents/configs/pulse-merge-stuck.conf`. Env vars
take precedence (set in `~/.aidevops/.env` or shell):

| Variable | Default | Purpose |
| --- | --- | --- |
| `AIDEVOPS_MERGE_STUCK_AGE_MINUTES` | `240` | Idle threshold (minutes) — only PRs idle this long are classified. |
| `AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES` | `5` | Consecutive zero-progress cycles before the framework-level meta-issue fires. |
| `AIDEVOPS_MERGE_PATTERN_MIN_PRS` | `3` | Minimum stuck PRs sharing one fingerprint before an outage meta-issue fires. |
| `AIDEVOPS_MERGE_STUCK_ENABLED` | `1` | Master kill-switch (set to `0` to disable the entire module). |

## 404 distinction in `_check_required_checks_passing`

`pulse-merge-process.sh::_check_required_checks_passing` historically failed
closed on **any** non-zero exit from the branch-protection API call (t2922).
This silently blocked merges on repos with **no branch protection rules** —
the most common shape for personal/draft repos and the canonical `origin/main`
of every fresh aidevops-init'd repo.

t3193 tightens the failure mode: HTTP 404 (no protection) returns 0 (allow),
falling through to the actual rollup gate (`_pr_required_checks_pass`) which
already evaluates real check state. Any other failure (401, 403, 5xx, network
error) preserves the t2922 fail-closed behaviour so an auth break cannot
silently unblock a stale fork PR.

## Dedup markers

Each escalation uses an idempotent HTML marker so repeat cycles do not spam:

| Marker | Where | Lifecycle |
| --- | --- | --- |
| `<!-- merge-stuck:individual -->` | Issue (or PR) comment | One per linked issue. Survives repeat stuck cycles. A new cycle on a different stuck PR linked to the same issue will not re-fire. |
| `<!-- merge-stuck:pattern:<hash16> -->` | Outage meta-issue body | One per failure fingerprint (sorted FAILURE check names, sha256 first 16 hex chars). Different outage signatures get different issues. |
| `<!-- merge-stuck:zero-progress -->` | Framework meta-issue body | One per active streak. Reset by any successful merge. |
| `<!-- pulse-rebase-nudge -->` | Reused from existing nudge family | Reused so `STUCK_CONFLICT_NO_NUDGE_LABEL` cannot double-fire alongside `_post_rebase_nudge_on_*`. |

## Counters added

All four are written to `~/.aidevops/logs/pulse-stats.json`:

| Counter | Type | Reset condition |
| --- | --- | --- |
| `pulse_merge_eligible_stuck_pr_count` | Gauge | Overwritten each cycle |
| `pulse_merge_zero_progress_cycles` | Gauge | Reset to 0 on any successful merge |
| `pulse_merge_branchprotect_404_skips` | Event counter | 24h rolling window (per t2424 pattern) |
| `pulse_merge_stuck_escalations_filed` | Event counter | 24h rolling window |

The first two use the new `pulse_stats_set_gauge` / `pulse_stats_get_gauge`
functions in `pulse-stats-helper.sh` — gauges store under `.gauges.<name>`
and represent a single current value, distinct from the per-event counter
namespace.

## Suppression: pulse circuit breaker interaction

When `pulse_dispatch_circuit_broken` (the t2690 GraphQL emergency floor) has
fired in the last 24h, the zero-progress meta-issue is **suppressed** —
filing a "pulse made no progress" investigation when the circuit breaker is
already advertising its own cause would only create noise. The per-PR
escalations and pattern-outage meta-issues are NOT suppressed; they remain
useful even during a rate-limit event.

## Disabling

Set `AIDEVOPS_MERGE_STUCK_ENABLED=0` in your env. The module's entry point
`pulse_merge_stuck_run_pass` short-circuits on the disabled flag.

## Test surface

`.agents/scripts/tests/test-pulse-merge-stuck.sh` covers:

- conf file integrity (4 entries present)
- defaults applied as positive integers post-source
- `_pms_iso_to_epoch` round-trip + garbage rejection
- `_pms_hash_fingerprint` 16-char hex output, deterministic, distinct inputs
- `pulse_stats_set_gauge` / `pulse_stats_get_gauge` round-trip + non-numeric
  rejection + gauge isolation
- `pulse_merge_zero_progress_record` state transitions (reset on merge,
  no-op on idle, increment on stuck cycle)
- shellcheck cleanliness on the module + the stats helper

Functions that require live GitHub API (`_classify_stuck_pr`,
`_escalate_individual_stuck_pr`, `pulse_merge_stuck_run_pass`,
`_pms_count_eligible_unmerged_for_repo`) are not unit-tested — they're
integration-level and exercise live PRs each pulse cycle.

## Related

- `pulse-merge-process.sh` — the deterministic merge pass; the module hooks
  in via `merge_ready_prs_all_repos`.
- `pulse-merge-conflict.sh` — the existing per-label rebase-nudge family.
- `pulse-merge-feedback.sh` — the conflict-feedback dispatch path.
- `reference/auto-merge.md` — full merge-gate semantics.
- `reference/cross-runner-coordination.md` — pulse cycle infrastructure.
- t2922 — the original fail-closed change in `_check_required_checks_passing`
  that t3193 partially tightens.
- t2690 — the pulse dispatch circuit breaker that suppresses the
  zero-progress meta-issue.
