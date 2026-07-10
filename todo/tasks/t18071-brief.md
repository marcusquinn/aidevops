---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18071: Establish privacy-safe linter forensics and bounded resource baselines

## Pre-flight

- [x] Memory recall: `linter CPU RAM crashes resource limits` → 0 hits — no reusable prior lesson found
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs surfaced for the target planning files in the prework window
- [x] File refs verified: 5 refs checked, all present at HEAD
- [x] Tier: `tier:thinking` — forensic attribution and cross-target safety decisions require judgment
- [x] Seeded draft PR decision recorded: skipped — evidence must be gathered locally before a safe implementation seed exists

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode:ses_0b6078816ffebb5VUpgvjShRvx
- **Created by:** AI DevOps (ai-interactive)
- **Parent mission:** m-20260710-11431d
- **Blocked by:** none
- **Conversation context:** The user reported suspected lint-related CPU saturation and reboots and requested privacy-first analysis of session history, system logs, and three linting environments.

## What

Create a redacted evidence matrix and a bounded benchmark contract that records aggregate wall time, CPU time, peak RSS, process count, cache state, coverage digest, and exit status while reliably terminating timed-out process trees.

## Why

The crash trigger is not yet proven. Safe measurements and confidence labels are required before changing concurrency, caches, traversal, or gate coverage.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** No — helper, tests, and redacted report are expected.
- [x] **Every target file under 500 lines?** No — multiple lint orchestrators require selective navigation.
- [x] **Exact replacements available?** No — evidence determines the retained implementation.
- [x] **No judgment or design decisions?** No — causal confidence and stop decisions require judgment.
- [x] **No fallback logic to design?** No — timeout cleanup must fail closed.
- [x] **No cross-module changes?** No — instrumentation and fixtures are separate concerns.
- [x] **Estimate 1h or less?** Yes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification checked?** Yes — no self-hosting dispatch file is targeted.

**Selected tier:** `tier:thinking`

**Tier rationale:** Local forensic interpretation plus safe process-tree termination crosses scripts, diagnostics, and private target boundaries.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A seed before evidence collection would anchor workers to an unverified crash hypothesis.
- **Status:** `not-created`
- **Freshness evidence:** Current lint entrypoints and mission constraints were inspected on 2026-07-10.
- **Verification run:** Planning-only; no unsafe benchmark was run.
- **Stale-assumption warning:** Any newer resource guard or correlated shutdown evidence requires re-evaluation.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/lint-resource-benchmark.sh` — bounded, serialized aggregate measurement wrapper.
- `NEW: .agents/scripts/tests/test-lint-resource-benchmark.sh` — timeout, process-tree cleanup, and redaction fixtures.
- `NEW: todo/missions/m-20260710-11431d/research/resource-baseline.md` — redacted evidence matrix only.

### Implementation Steps

1. Collect only aggregate evidence from recent session records and relevant system diagnostics; keep raw records local.
2. Implement a wrapper shaped as follows, following `shared-constants.sh` conventions:

```bash
run_bounded_lint_profile() {
	local profile_name="$1"
	local timeout_seconds="$2"
	local command_name="$3"
	# Acquire a single-run lock, sample aggregate metrics, and execute in a process group.
	# On timeout or safety signal, terminate the complete group and report failure.
	return 0
}
```

3. Add fixtures for normal completion, timeout, descendant cleanup, and path/log redaction.
4. Run only one changed-mode baseline after guards pass; do not reproduce a crash.

### Verification

```bash
bash .agents/scripts/tests/test-lint-resource-benchmark.sh
shellcheck .agents/scripts/lint-resource-benchmark.sh .agents/scripts/tests/test-lint-resource-benchmark.sh
```

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-lint-resource-benchmark.sh`
- [ ] WIP commit created before broad gates: `wip: add bounded lint resource baseline`
- [ ] Broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/scripts/lint-resource-benchmark.sh`
- `.agents/scripts/tests/test-lint-resource-benchmark.sh`
- `todo/missions/m-20260710-11431d/research/resource-baseline.md`

## Acceptance Criteria

- [ ] Timeout fixtures fail closed and leave no child process running.
- [ ] Committed evidence contains aggregate metrics and confidence labels but no raw logs, private names, or local paths.
- [ ] A bounded changed-mode baseline completes without a safety trigger.
- [ ] Suspected crash causation is labelled unproven unless independent evidence corroborates it.

## Context & Decisions

- Benchmarks are serialized and local concurrency starts at 1.
- Stop thresholds and performance acceptance thresholds come from the mission state file.
- Unsafe results are inconclusive and are never retried in the same profile.

## Relevant Files

- `.agents/scripts/linters-local.sh:33-45` — current execution modes and timeout controls.
- `.agents/scripts/tests/test-linters-local-ratchet-timeout.sh` — existing timeout fixture pattern.
- `.agents/reference/diagnostics-discipline.md` — evidence and attribution rules.
- `.agents/reference/memory-lookup.md` — local session lookup rules.
- `todo/missions/m-20260710-11431d/mission.md` — safety and privacy contract.

## Dependencies

- **Blocked by:** none
- **Blocks:** t18072, t18073, t18074
- **External:** none; raw local diagnostics must not leave the machine

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Select bounded evidence windows and entrypoints |
| Implementation | 15m | Wrapper, redaction, and report skeleton |
| Testing | 5m | Focused termination fixtures |
| **Total** | **30m** | |
