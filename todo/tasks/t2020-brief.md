---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2020: refactor(pulse): split pulse-simplification.sh state cluster below 2000 LOC gate

## Origin

- **Created:** 2026-04-13
- **Session:** Claude:interactive
- **Created by:** marcusquinn (ai-interactive, while unblocking #18420)
- **Parent task:** none (supersedes stale #18400 / t1987 broad Phase 12 sweep)
- **Conversation context:** The user flagged that #18420 (t1993, "schedule post-merge-review-scanner.sh") was stuck behind the large-file simplification gate. Investigation found that `pulse-simplification.sh` was 2,058 lines (58 over the 2,000-line threshold), that the broad Phase 12 sweep tracked as #18400/t1987 had been stale for ~6 hours (worker PID 1132783 no longer running, no PR, no activity), and that the same pattern had already been shipped as t2013 / PR #18460 for `headless-runtime-helper.sh`. The user approved a surgical split mirroring that precedent.

## What

Extract the `_simplification_state_*` sub-cluster (7 functions, 450 lines) from `pulse-simplification.sh` into a new sibling module `pulse-simplification-state.sh`, sourced by `pulse-wrapper.sh` immediately after the parent. The parent file drops from 2,058 to ~1,617 lines — clearing the simplification gate with comfortable headroom for t1993's new `_run_post_merge_review_scanner` function (~50 lines).

End-state:

- `.agents/scripts/pulse-simplification.sh` — 1,617 lines, unchanged content except removal of the state cluster and an updated header.
- `.agents/scripts/pulse-simplification-state.sh` — new file, ~504 lines, contains the 7 extracted functions byte-identical to their pre-extraction form plus a module header and include guard.
- `.agents/scripts/pulse-wrapper.sh` — adds `source "${SCRIPT_DIR}/pulse-simplification-state.sh"` after the existing `pulse-simplification.sh` source, and `_PULSE_SIMPLIFICATION_STATE_LOADED` in the `--self-check` module-guard list.
- `#18420` (t1993) no longer gated by `needs-simplification` on the next pulse re-evaluation.

## Why

**The immediate trigger.** #18420 was blocked by the large-file gate (`_issue_targets_large_files` in `pulse-dispatch-core.sh:657`). Every pulse cycle that tried to dispatch a worker on #18420 was short-circuited at the gate because the target file was 58 lines over threshold. t1993 is a small feature (`_run_post_merge_review_scanner`, ~50 lines) that would push the file further over — so even if we bypassed the gate manually, the next cycle would re-gate it.

**Why the broad sweep wasn't the answer.** #18400/t1987 was labelled "refactor(pulse): Phase 12 simplification sweep" — broad scope covering multiple files and multiple sub-clusters. It had been claimed by a worker (PID 1132783 at 2026-04-12T19:04:03Z) but that worker died without producing a PR, and no follow-up activity had happened for ~6 hours. The issue was effectively abandoned. Broad sweeps are the wrong granularity for tier-based worker dispatch: they accumulate too much context and fail more often than they succeed.

**The precedent.** PR #18460 (t2013) shipped yesterday with the exact same pattern for `headless-runtime-helper.sh`: narrow surgical split, one sub-cluster extracted into a sibling file. That's the shape this problem wants.

**Why the state cluster.** The `_simplification_state_*` functions are the most self-contained sub-cluster in `pulse-simplification.sh`. They share a single concern (reading/writing `.agents/configs/simplification-state.json`), only call each other and one external helper (`_complexity_scan_has_existing_issue`), and account for 450 lines — enough to drop the parent well below threshold. The call-graph boundary is clean; no refactoring is needed.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** — no (3 files: parent, new module, wrapper; plus characterization test touches — still 4)
- [x] **Complete code blocks for every edit?** — yes, the extraction is byte-identical + a templated header
- [x] **No judgment or design decisions?** — the cluster boundary and naming are both fixed by prior art (t2013 pattern, existing header in parent file)
- [x] **No error handling or fallback logic to design?** — byte-identical move, no new logic
- [x] **Estimate 1h or less?** — ~45m-1h total
- [ ] **4 or fewer acceptance criteria?** — 6 criteria

**Selected tier:** `tier:standard`

**Tier rationale:** Mechanical extraction mirroring a known pattern — Sonnet handles this reliably. The file count (4) disqualifies `tier:simple` and the acceptance-criteria count crosses the threshold, but no architectural judgment is required.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-simplification.sh` — remove lines 564–1013 (the state cluster + leading comment block); update the header comment to list the extracted functions under a new "Functions moved to pulse-simplification-state.sh" section.
- `NEW: .agents/scripts/pulse-simplification-state.sh` — new file with a module header, include guard (`_PULSE_SIMPLIFICATION_STATE_LOADED`), and the 7 extracted functions byte-identical to their pre-extraction form.
- `EDIT: .agents/scripts/pulse-wrapper.sh` — add `source "${SCRIPT_DIR}/pulse-simplification-state.sh"` after the existing `source "${SCRIPT_DIR}/pulse-simplification.sh"` at line 155; add `_PULSE_SIMPLIFICATION_STATE_LOADED` to the self-check module guard list at line 976.
- `VERIFY: .agents/scripts/tests/test-pulse-wrapper-characterization.sh` — no changes needed. The test sources `pulse-wrapper.sh` and checks function existence via Bash's `declare -f`, which finds functions regardless of which module file defined them. Run the test to confirm.

### Reference pattern

- PR #18460 / t2013 (`refactor/headless-runtime-simplify` branch) — the same surgical split for `headless-runtime-helper.sh`. Model the extraction boundary logic on that PR.
- The parent file's own header comment at `pulse-simplification.sh:6-55` documents the Phase 6 extraction from `pulse-wrapper.sh` — mirror that structure for the new module header.

### Extracted functions

From `pulse-simplification.sh` lines 564–1013 (original numbering):

1. `_simplification_state_check` (570–617)
2. `_simplification_state_record` (622–657)
3. `_simplification_state_refresh` (666–720)
4. `_simplification_state_prune` (728–782)
5. `_simplification_state_push` (786–808)
6. `_create_requeue_issue` (821–895)
7. `_simplification_state_backfill_closed` (906–1013)

All 7 functions are listed in `test-pulse-wrapper-characterization.sh:191-197` — do not remove them from the test, since Bash resolves them by name regardless of module.

### Cross-module call

`_simplification_state_backfill_closed` calls `_complexity_scan_has_existing_issue` at line 991 (original numbering). That function stays in `pulse-simplification.sh` (defined at line 1028 in the original, ~1015 after extraction). Bash resolves function names at call time, so as long as both modules are sourced by `pulse-wrapper.sh` before `_simplification_state_backfill_closed` is invoked, the call works unchanged. The `source "${SCRIPT_DIR}/pulse-simplification-state.sh"` line must be added AFTER the existing `pulse-simplification.sh` source to read correctly ("parent, then state sub-cluster"), but strictly speaking the order doesn't matter — either sequence works.

### Verification

```bash
# Line counts
wc -l .agents/scripts/pulse-simplification.sh         # target: ~1617
wc -l .agents/scripts/pulse-simplification-state.sh   # expected: ~504

# Syntax
bash -n .agents/scripts/pulse-simplification.sh
bash -n .agents/scripts/pulse-simplification-state.sh
bash -n .agents/scripts/pulse-wrapper.sh

# Shellcheck
shellcheck .agents/scripts/pulse-simplification.sh \
  .agents/scripts/pulse-simplification-state.sh \
  .agents/scripts/pulse-wrapper.sh

# Characterization test (sources wrapper, checks function existence)
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
# Expect: "PASS all 205 pulse-wrapper functions defined after sourcing"

# Self-check sees the new module guard
.agents/scripts/pulse-wrapper.sh --self-check
# Expect: "self-check: ok (28 canonical functions defined, 24 module guards verified)"
```

## Acceptance Criteria

- [ ] `pulse-simplification.sh` is under 2,000 lines.
  ```yaml
  verify:
    method: bash
    run: "test $(wc -l < .agents/scripts/pulse-simplification.sh) -lt 2000"
  ```
- [ ] `pulse-simplification-state.sh` exists and contains the 7 state functions.
  ```yaml
  verify:
    method: bash
    run: "for f in _simplification_state_check _simplification_state_record _simplification_state_refresh _simplification_state_prune _simplification_state_push _create_requeue_issue _simplification_state_backfill_closed; do grep -q \"^${f}()\" .agents/scripts/pulse-simplification-state.sh || { echo \"missing: $f\"; exit 1; }; done"
  ```
- [ ] `pulse-wrapper.sh` sources the new module and registers its load guard.
  ```yaml
  verify:
    method: codebase
    pattern: "source .*pulse-simplification-state.sh"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] Shellcheck clean on all three files.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-simplification.sh .agents/scripts/pulse-simplification-state.sh .agents/scripts/pulse-wrapper.sh"
  ```
- [ ] Characterization test passes — all 205 pulse-wrapper functions still defined after sourcing.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh 2>&1 | grep -q 'All 26 tests passed'"
  ```
- [ ] Self-check reports the new module guard.
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/pulse-wrapper.sh --self-check 2>&1 | grep -q '24 module guards verified'"
  ```

## Context & Decisions

**Why surgical, not broad.** The stale broad Phase 12 sweep (#18400/t1987) is evidence that tier-based worker dispatch struggles with multi-file sweeps. A single worker needs to load too much context to make a good split-point decision across multiple files. Narrow surgical splits — one sub-cluster at a time, with a known precedent — are the only pattern that reliably ships.

**Why the state cluster specifically.** Three sub-clusters in `pulse-simplification.sh` could plausibly be extracted: (1) complexity-scan (lines 64–562 + 1028–1579, too large and entangled with dispatch logic), (2) state registry (lines 564–1013, self-contained, 450 lines — the right size), (3) weekly complexity scan (lines 1594–2058, too tightly coupled to the complexity-scan internals). State was the obvious choice — cohesive by concern, clean call-graph boundary, and big enough to clear the gate in one move.

**Why not ship the t1993 function in the same PR.** Two reasons: (1) the t1993 brief asks a worker to add the new function, so shipping it as part of this PR would claim the worker's task without a proper task assignment; (2) the split should be reviewable as a pure byte-preserving refactor, not mixed with new feature code. The split unblocks t1993 for the next pulse cycle.

**Why close #18400 as not-planned rather than leaving it open.** Broad sweeps dispatch with `tier:reasoning` and stall at ~5h timeout, burning Opus budget without producing output. Leaving the issue open invites re-dispatch. Closing with a link to this PR and a note that future sub-cluster splits should be narrow tasks, not broad sweeps, is the correct framing.

**Gate bug discovered during investigation.** The gate comment on #18420 says "Simplification issues: none created" because `_issue_targets_large_files` at `pulse-dispatch-core.sh:828` uses `gh issue create ... --json number --jq '.number'`, but `gh issue create` doesn't support `--json` (confirmed via `gh issue create --help`). Tracked as t2021/#18484 for a separate worker — not in scope for this PR.

**Non-goals:**

- Simplification of the extracted or remaining functions (byte-identical move only).
- Splitting other sub-clusters in `pulse-simplification.sh` (separate narrow tasks if further cuts are needed).
- Fixing the `gh issue create --json` gate bug (tracked as t2021).
- Touching `pulse-prefetch.sh` or other files #18400 originally intended to sweep.

## Relevant Files

- `.agents/scripts/pulse-simplification.sh` — parent file, extraction source.
- `.agents/scripts/pulse-simplification-state.sh` — new module.
- `.agents/scripts/pulse-wrapper.sh:155` — existing parent source line.
- `.agents/scripts/pulse-wrapper.sh:976` — existing module-guard list.
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh:191-197` — function-existence checks (no change needed).
- `.agents/scripts/pulse-dispatch-core.sh:657-879` — `_issue_targets_large_files`, the gate that was blocking #18420.
- PR #18460 — prior precedent (`headless-runtime-helper.sh` split).
- Closed as not-planned: #18400 / t1987 (superseded by this narrow split).

## Dependencies

- **Blocked by:** none
- **Blocks:** #18420 (t1993) — unblocks once merged and the next pulse cycle re-evaluates the gate
- **Supersedes:** #18400 (t1987) — broad Phase 12 sweep, stale and abandoned
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read + plan | 10m | Identify the state cluster, confirm call-graph boundary |
| Extract + create module | 15m | `sed` the range, wrap in module header |
| Remove from parent + update header | 10m | Single multi-line edit |
| Wrapper source + guard list | 5m | Two small edits |
| Shellcheck + bash -n + characterization test | 10m | Automated |
| Brief + TODO + commit + PR | 15m | |
| **Total** | **~65m** | |
