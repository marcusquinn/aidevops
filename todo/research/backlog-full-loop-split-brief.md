<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

_Supersedes #31068 — this issue is the consolidated spec._

## What

Bring `.agents/scripts/full-loop-helper-commit.sh` below the existing 2000-line
dispatch limit by mechanically extracting its cohesive remote-readiness and
pre-merge gate group. Preserve behavior, public functions and shell state.

## Why and reproducer

**Symptom command:** `wc -l .agents/scripts/full-loop-helper-commit.sh`

**Actual output:** Current source after merged PR #33458 has 2362 lines, above
the dispatch limit. The historic validator extraction in #31069 was delivered,
but subsequent growth means it cannot close the current debt.

The operational consolidation task #33457 targets this same large file and has
no active dispatch. This successor preserves substantive history without
dispatching a consolidation worker into the same simplification deadlock.

## How

Read `.agents/reference/large-file-split.md`, the parent library's source header,
and the readiness group. Current group runs from
`_full_loop_persist_pr_check_evidence` through `cmd_pre_merge_gate` (roughly
lines 65–535); confirm exact boundaries on the fetched default branch.

Extract those complete function bodies into
`.agents/scripts/full-loop-helper-readiness.sh`, with a unique include guard,
defensive source-path fallback and normal ShellCheck source directives. Keep
existing constants, includes and validator/commit/PR functions in the parent;
source the new module through `_FULL_LOOP_COMMIT_DIR` so isolated fixtures with
a custom `SCRIPT_DIR` still work. Functions and arguments stay available through
the original source contract. Preserve dynamic caller-owned state, transition
locks, API backpressure, exact-head verification, authority and review guards.

In particular, preserve #33458's exact `skipping` + `SKIPPED` admission rule and
its pending/failure/unknown classifications. Do not restore broad skip acceptance.
No behavior, release, deployment, credentials or configuration change is in scope.

Reference patterns: existing `full-loop-helper-commit-validators.sh`, the parent
include guard and `_FULL_LOOP_COMMIT_DIR`, plus `issue-sync-helper.sh` and
`issue-sync-lib.sh`. Mechanical body identity and normal CLI/source paths are
the strongest verification; do not add a new runner or test-only interface.

### Complexity Impact

Run the existing scoped scanner before extraction. Keep any function over
100 lines at its existing identity; the ten cited readiness functions are
currently bounded but must be recounted. Original library must finish below
2000 lines, and the new module below 1500. Do not pre-apply historical override
labels: the current AST nesting scanner fixed the old false positives. Actual
new complexity must be repaired rather than hidden by an override.

## Files Scope

- EDIT: .agents/scripts/full-loop-helper-commit.sh
- NEW: .agents/scripts/full-loop-helper-readiness.sh
- EDIT: .agents/scripts/tests/test-full-loop-remote-evidence.sh
- EDIT: .agents/scripts/tests/test-full-loop-efficient-orchestration.sh

The test files are conditional: change only import/copy fixtures if needed by
the new sibling; keep all current cases and assertions. No other writer scope.

## Acceptance Criteria

- [ ] Original source is below 2000 lines; extracted module is below 1500.
- [ ] Moved function bodies, names, arguments, caller state and behavior match.
- [ ] Include/source idempotency and direct/sourced CLI paths remain available.
- [ ] Existing remote-evidence suite still passes its 29 assertions, including
  skip admission and fail-closed cancellation, unknown and pending cases.
- [ ] Existing efficient-orchestration, commit/PR validator and relevant source
  fixtures pass; syntax, ShellCheck and changed-file gates pass on the exact head.
- [ ] Ready PR includes immutable head, test/runtime output and review bundle;
  parent performs independent closeout review, integration and issue disposition.

## Verification

Use the existing normal routes, not paid providers or production services:

```bash
bash -n .agents/scripts/full-loop-helper-commit.sh
bash -n .agents/scripts/full-loop-helper-readiness.sh
shellcheck .agents/scripts/full-loop-helper-commit.sh .agents/scripts/full-loop-helper-readiness.sh
bash .agents/scripts/tests/test-full-loop-remote-evidence.sh
bash .agents/scripts/tests/test-full-loop-efficient-orchestration.sh
.agents/scripts/linters-local.sh --changed
```

Discover the existing commit/PR source fixtures by exact tracked-file search;
do not expand to unrelated full-repository gates. Do not mutate a live PR to
manufacture runtime evidence. Parent supplies independent high-risk review.

## Context and contributors

- Per @vladimirdulov, #31069 extracted validator execution, taking the original
  source from 2014 to 1864 lines. Keep that delivered extraction unchanged.
- Per @alex-solovyev, self-hosting code requires `tier:thinking`; retain that
  workload tier without pinning a provider or bypassing the detector.
- Historical parent text predicted complexity overrides. Current playbook
  explicitly says the old AST false positives are resolved; overrides require
  real current scanner evidence, not that historic prediction.
- Parent backlog mission owns integration/release. This unit is disjoint from
  #33459's review helper and workflow/documentation surfaces.

cc @alex-solovyev @vladimirdulov @marcusquinn

[effort:thinking] Implement and verify only this surface. Do not merge, release,
delegate again, edit shared mission planning, or weaken guards. Return a ready PR
and exact evidence to the parent. No new spending or production-service authority.
