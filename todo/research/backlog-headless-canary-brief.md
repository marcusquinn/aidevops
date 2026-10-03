<!-- aidevops:brief-schema=v2 -->

_Supersedes #28838 — this issue is the consolidated spec._

## Pre-flight

- [x] Memory recall: backlog/headless runtime mission → no relevant lessons.
- [x] Discovery pass: seven commit matches, one historical split PR (#19821),
  no open related PRs; current code still has 2300 lines.
- [x] File refs verified: runtime library, existing helper/candidate suites and
  split playbook are present. New canary library is not yet present.
- [x] Tier: thinking — self-hosting dispatch-path override.
- [x] Seeded draft PR: skipped; preserve the current source through a mechanical
  extraction, not a speculative seed.

## What

Bring `.agents/scripts/headless-runtime-lib.sh` below the existing 2000-line
dispatch limit by extracting its cohesive canary helpers into a sourced library.
Preserve behavior, function signatures, shell state and all safety checks.

## Why

Issue #28838 was legitimately reopened after the previous split regrew. Current main
has 2300 lines, not a stale/deleted target. #33327's consolidation was itself held
by the same large-file/scope problem. This bounded successor replaces both
threads without claiming their implementation is already complete.

## Tier

Selected tier: `tier:thinking`; worker launch health checks are self-hosting.

## How

### Files to Modify

- EDIT: `.agents/scripts/headless-runtime-lib.sh`
- NEW: `.agents/scripts/headless-runtime-canary.sh`
- EDIT if fixture imports require it: the two existing suites in Files Scope.

### Complete Write Surface

The caller is `headless-runtime-helper.sh`; existing runtime libraries and tests
source the original library. Retain its include guard, constants, `SCRIPT_DIR`
fallback and existing source order. Deploy copies scripts through normal setup;
no custom deployment or configuration change is required.

### Implementation Steps

1. Revalidate current main and run the existing scoped complexity check before
   extracting. Keep any >100-line function in its original file.
2. Current canary group spans roughly lines 1956–2294. It contains the compatibility
   overload stub plus `_classify_canary_failure_reason`,
   `_record_canary_provider_backoff`, `_canary_pass_cache_is_fresh`,
   `_canary_negative_cache_is_active`, `_resolve_canary_opencode_binary`,
   `_select_canary_model`, `_prepare_canary_isolation`, `_execute_canary_probe`,
   `_cleanup_canary_isolation`, `_canary_output_is_success`,
   `_record_canary_failure` and `_run_canary_test`.
3. Follow `reference/large-file-split.md`: unique include guard, defensive
   `SCRIPT_DIR`, shared-constant discipline, explicit returns and ShellCheck
   source directives. Keep these bodies byte-identical where practical. Current
   `_run_canary_test` is 44 lines, unlike the historical >100-line precedent.
4. Source the new library at the original canary location, before the existing
   model-library source. Do not change runtime selection, provider/authentication
   isolation, negative-cache TTLs, timeouts, backoff, lease/ownership or cleanup.
5. Update only existing test fixture import/copy lists that require the new
   sibling. No new runner, test-only interface, or broad format churn.

### Complexity Impact

This is a mechanical file split, not function growth. Moving the roughly
339-line group should leave the original below 2000 and the new library well
below 1500. Do not move an oversized function into a new scanner identity. Any
claimed identity-key false positive needs exact scanner evidence and the normal
justification path; never disable hooks, lower thresholds or hide real growth.

### Hazards and Compatibility

Preserve Bash 3.2 and Linux/macOS behavior, direct/sourced invocation, include
idempotency, dynamic shell variables, fake-runtime fixtures and failure cleanup.
Keep original model-library sourcing. Existing credential-scoping code is not
an invitation to read or expose credentials. No live paid/provider canary is
needed to verify a mechanical split; use the normal isolated fixture paths.

Concurrent #33113 owns Pulse wrapper/runtime-pin/lifecycle files. Do not edit
those or `headless-runtime-worker.sh`; request serialization if a real dependency
outside this surface appears.

### Verification Before Dispatch

Run syntax, ShellCheck, changed-file lint and existing helper/candidate suites:

```bash
bash .agents/scripts/tests/test-headless-runtime-helper.sh
bash .agents/scripts/tests/test-headless-runtime-opencode-candidates.sh
```

Exercise normal source/CLI paths twice to verify complete function availability,
idempotency, canary classification/cache behavior and unchanged exits. Independent
closeout review is required for the high-risk runtime boundary.

### Files Scope

- `.agents/scripts/headless-runtime-lib.sh`
- `.agents/scripts/headless-runtime-canary.sh`
- `.agents/scripts/tests/test-headless-runtime-helper.sh`
- `.agents/scripts/tests/test-headless-runtime-opencode-candidates.sh`

## Acceptance Criteria

- [ ] Original library has fewer than 2000 lines; extracted module is below 1500.
- [ ] Public/private function names, arguments and runtime behavior are preserved.
- [ ] Missing runtime, cached failure, timeout and provider classification remain
  fail-closed; isolation and cleanup protections are unchanged.
- [ ] Existing verification and applicable required checks pass on the exact head.
- [ ] Push a ready successor PR with a closing reference to this issue; parent
  reviews, integrates, verifies closure and owns the authorized final release.

## Context & Decisions

- Per @alex-solovyev: historical PR #28842 did complete an earlier split; that
  evidence cannot close a file that subsequently regrew.
- Per @marcusquinn: the 2026-10-01 reopening and stale-assignment recovery were
  valid; retain normal dispatch eligibility and thinking-tier self-hosting scope.
- Per @vladimirdulov: consolidate substantive history and @mention contributors;
  preserve an explicit auto-dispatch successor rather than an indefinite hold.
- Current playbook says the old nesting-scanner false positives were repaired.
  Do not preemptively apply a complexity exception from an obsolete template.

[effort:thinking] Do not merge, release, delegate, or edit shared mission planning.
Return exact head, tests, review digest and any real blocker to the parent.

## Contributors

cc @alex-solovyev @marcusquinn @vladimirdulov

<!-- aidevops:origin:interactive -->
