<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Dispatch Architecture — gh API Call Budget

This document describes the gh-API call budget enforced inside the
`dispatch_with_dedup` orchestrator and the gates it delegates to. It
is the canonical reference for "how many gh calls per dispatch
candidate" and the t2996 invariant that keeps that number bounded.

## Why a budget exists

Each `gh issue view` / `gh api` call costs ~0.5-2s in steady state and
spikes to 5s+ under load (rate-limit pressure, large response bodies,
network latency). The pulse's `_dff_dispatch_with_timeout` enforces a
30-second per-candidate ceiling (t2989, env
`FILL_FLOOR_PER_CANDIDATE_TIMEOUT`). When the gate pipeline made
10-15 serial gh calls per candidate, every dispatch decision sat on
the timeout cliff:

```text
fill_floor_candidate_3050    33s   rc=124 (timeout)
fill_floor_candidate_3078    32s   rc=124 (timeout)
fill_floor_candidate_3012    32s   rc=124 (timeout)
fill_floor_candidate_21390   32s   rc=124 (timeout)
fill_floor_candidate_21403   32s   rc=124 (timeout)
fill_floor_candidate_21387   32s   rc=124 (timeout)
fill_floor_candidate_3361    31s   rc=1   (just under wire — no dispatch)
fill_floor_candidate_3366    31s   rc=1   (just under wire)
```

`pulse_stats.json::fill_floor_per_candidate_timeout` reached 37 events
in 24h before t2996 landed.

## The canonical bundle (t2996)

`dispatch_with_dedup` makes ONE `gh issue view` call up front and
threads the result through every downstream gate that needs issue
metadata:

```bash
issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
    --json number,title,state,labels,assignees,body 2>/dev/null)
```

Every gate that previously fetched a subset of these fields now reads
them from `$issue_meta_json` via `jq -r`:

| Gate | Pre-t2996 fetches | Post-t2996 source |
|---|---|---|
| `_dispatch_dedup_check_layers` (state, title, labels) | bundled in main fetch | `jq -r '.state // ""'` etc. |
| `_check_nmr_approval_gate` | label inspection | `jq -e '.labels \| ...'` (already optimal) |
| `_check_commit_subject_dedup_gate` (force-dispatch / cache labels) | label inspection | `jq -e '.labels \| ...'` (already optimal) |
| Blocked-by check (`is_blocked_by_unresolved`) | `gh issue view --json body` | `jq -r '.body // ""'` |
| `_issue_needs_consolidation` (labels) | `gh issue view --json labels` | `jq -r '[.labels[].name] \| join(",")'` via `pre_fetched_json` arg 3 |
| `_issue_targets_large_files` (labels) | `gh issue view --json labels` | `jq -r '[.labels[].name] \| join(",")'` via `pre_fetched_json` arg 6 |
| `_issue_targets_large_files` (title for surgical-brief check) | `gh issue view --json title` | `jq -r '.title // ""'` via `pre_fetched_json` arg 6 |
| `_ensure_issue_body_has_brief` (body) | `gh issue view --json body` | `jq -r '.body // ""'` via `pre_fetched_json` arg 5 |
| `check_dispatch_dedup` Layer 6 (`is-assigned`) | `gh issue view --json labels,assignees` | `ISSUE_META_JSON` env var passed through (existing helper-side optimization at `dispatch-dedup-helper.sh:898-900`) |

The `_run_eligibility_gate_or_abort` path (t2424) was already wired
through `ISSUE_META_JSON` when t2996 landed.

## Budget invariant

Every code path that runs as part of a dispatch decision must satisfy:

| Function | gh issue view calls allowed |
|---|---|
| `dispatch_with_dedup` | **exactly 1** — the canonical bundle |
| `_dispatch_dedup_check_layers` | **0** — every metadata need flows through `$issue_meta_json` |
| `_issue_needs_consolidation` (when called from dispatch) | 0 (1 fallback for re-evaluation paths) |
| `_issue_targets_large_files` (when called from dispatch) | 0 (1-2 fallback for re-evaluation paths) |
| `_ensure_issue_body_has_brief` (when called from dispatch) | 0 (1 fallback for defence-in-depth callers) |

Conditional gh calls outside this budget are permitted when they
satisfy a guard condition that is **rare in steady state**:

- `_is_task_committed_to_main` makes 1 `gh issue view --json createdAt`
  call. Gated behind two label fast-paths (`force-dispatch` and the
  `dispatch-blocked:committed-to-main` cache from t2955) that catch
  the common case before the gh call fires.
- `_issue_needs_consolidation` makes 1 `gh api .../comments --paginate`
  call. Gated behind label fast-paths (`consolidated`,
  `needs-consolidation` already-applied) and a child-issue lookup.

## Regression protection

`.agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh` enforces
the invariant via static source analysis:

1. `dispatch_with_dedup` body fetches the canonical bundle with
   `body` included, in exactly one gh call.
2. `_dispatch_dedup_check_layers` makes zero `gh issue view` calls.
3. The three downstream gates (`_issue_needs_consolidation`,
   `_issue_targets_large_files`, `_ensure_issue_body_has_brief`)
   accept the optional `pre_fetched_json` parameter and derive their
   metadata via jq when present.
4. `ISSUE_META_JSON` is exported when calling `check_dispatch_dedup`
   so the helper-side optimization at
   `dispatch-dedup-helper.sh:898-900` fires.
5. `t2996` audit markers exist at every threading site so a `rg t2996`
   sweep finds the invariant.

A future contributor that re-introduces a per-gate gh call WILL
break one of these checks and fail CI with an explicit pointer at the
offending function.

## Adding a new gate

When adding a new pre-dispatch gate, follow the canonical pattern:

1. Accept `issue_meta_json` (the bundle) as the last argument or via
   the `ISSUE_META_JSON` env var.
2. Extract the fields you need with `jq -r '.field // ""'`.
3. Fall back to a fresh `gh issue view` only when the bundle is
   absent — typically only re-evaluation / defence-in-depth callers
   that may hold stale labels.
4. Add a `t2996` (or your task ID) comment at the threading site.
5. Update the budget table above and the regression test.

The fallback path keeps the helper self-sufficient so it can also be
called from re-evaluation paths in `pulse-triage.sh` that were never
designed to know about the dispatch bundle.

## Operational evidence

After t2996 deployed, expected observables:

```bash
# Counter should drop from baseline to <5 events / 24h.
jq '.counters.fill_floor_per_candidate_timeout' ~/.aidevops/logs/pulse-stats.json

# Average fill_floor candidate stage duration should drop below 15s.
awk '/fill_floor_candidate/ {sum+=$3; n++} END {if (n>0) print sum/n}' \
    ~/.aidevops/logs/pulse-stage-timings.log
```

If either metric regresses, run the regression test first
(`bash .agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh`)
to verify the source-level invariant still holds, then check the
gh-API instrumentation log
(`~/.aidevops/logs/gh-api-calls-by-stage.json`, t2902) for which
caller is over-spending.

## Related task IDs

- **t2989** — per-candidate 30s timeout (the cliff this budget protects against)
- **t2996** — bundle threading + this budget invariant
- **t2424** — `_run_eligibility_gate_or_abort` already used `ISSUE_META_JSON`
- **t2955** — `dispatch-blocked:committed-to-main` cache label
- **t2902** — gh API call instrumentation
- **t2574 / t2689 / t2744 / t2902** — REST-fallback wrappers that prevent
  GraphQL exhaustion under similar serial-call pressure
