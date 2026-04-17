<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2170: clear stale `needs-simplification` labels in pulse-triage — Fix E of t2163

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:interactive (Claude Sonnet 4.7)
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** t2163 / GH#19482 (5-fix plan)
- **Conversation context:** Filed after t2164 (Fixes A+B) merged. Closes the self-healing loop: Fix A+B address the gate at creation time, Fix D (t2169) addresses verification at merge time, and Fix E here proactively clears stale `needs-simplification` labels on previously-blocked issues so they self-unblock without waiting for a fresh dispatch attempt.

## What

Extend `_reevaluate_simplification_labels` in `.agents/scripts/pulse-triage.sh` to parse the large-file gate's sticky comment, identify cited continuation issues, and check whether those citations are stale (closed-but-file-still-over-threshold or closed-with-`simplification-incomplete`-label from Fix D). When ALL cited continuations are stale, remove the `needs-simplification` label proactively so the next dispatch cycle re-fires the gate — which, post-Fix-A/B, will file a fresh debt issue instead of re-citing the phantom.

## Why

Fix A+B (t2164) fix the gate at ISSUE CREATION time. New issues dispatched against large files won't be stuck. But:

- Issues already labeled `needs-simplification` (like GH#19415 before t2164 merged) stay labeled until the pulse attempts dispatch again and the gate re-runs. If the parent is blocked for days and the fix lands in between, nothing triggers a re-evaluation unless a human manually clears the label.
- The gate only clears `needs-simplification` when it re-runs and finds no offenders (`_large_file_gate_clear_stale_label` at line 422-428). But re-run only happens during dispatch, and dispatch is held by `needs-simplification`. This is a deadlock unless something external breaks it.

Fix E breaks the deadlock by adding a proactive re-evaluation in `pulse-triage.sh`, which runs on a different cadence than dispatch and already scans for stale labels (`_reevaluate_simplification_labels` exists at line 450-491).

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Single-file edit extending an existing helper, plus new regression tests. Narrative brief with file+line references. Not `tier:simple` because the comment-parsing logic needs to handle missing comments, multiple continuations, and edge cases (stale vs valid vs open). Not `tier:thinking` because the design is already fully specified here — extend existing function, parse known comment format, reuse Fix B's verification logic.

## How

### Root-cause finding (added 2026-04-17, verified empirically on GH#19415)

Investigation during t2164 merge confirmed a SECOND, simpler bug in the
auto-clear path that compounds the Fix E scope below. **This is the PRIMARY
bug to fix; the continuation-comment parsing below is secondary.**

**The bug:** `_issue_targets_large_files` in `pulse-dispatch-large-file-gate.sh`
at **line 654** does `[[ -n "$all_paths" ]] || return 1` — early-return when
path extraction is empty — BEFORE the auto-clear path at lines 682-684.

After Fix A (t2164) the extractor correctly returns empty for bodies with
no `EDIT:`/`NEW:`/`File:` intent markers (verified on GH#19415 body post-fix).
That means when `_reevaluate_simplification_labels` calls
`_issue_targets_large_files` with `force_recheck=true`:

1. precheck passes (force_recheck bypasses the "skip if labeled" guard)
2. `_large_file_gate_extract_paths` returns EMPTY (correct, per Fix A)
3. line 654 early-returns 1 — **never reaches line 682-684 auto-clear**
4. `_post_simplification_gate_cleared_comment` posts the "CLEARED" comment
   (misleading — label wasn't actually cleared)
5. **Label stays stuck indefinitely**

Empirical evidence: GH#19415 received the CLEARED comment at 2026-04-17T03:38:43Z
but the `needs-simplification` label persisted until manually removed during t2164
post-merge verification. 17 minutes of zero label events after pulse restart
confirmed extractor fix works (no more re-application) but the stale label
required human intervention to clear.

**Minimal fix (MANDATORY for this PR):**

In `pulse-dispatch-large-file-gate.sh` at line 654, replace:

```bash
all_paths=$(_large_file_gate_extract_paths "$issue_body")
[[ -n "$all_paths" ]] || return 1
```

with:

```bash
all_paths=$(_large_file_gate_extract_paths "$issue_body")
if [[ -z "$all_paths" ]]; then
    # No paths in body — if already labeled, auto-clear (stale label from
    # pre-Fix-A gate application that matched context-ref backtick paths).
    if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
        _large_file_gate_clear_stale_label "$issue_number" "$repo_slug"
    fi
    return 1
fi
```

This closes the gap for ALL issues where:
- pre-Fix-A gate fired incorrectly on a body with no edit-intent markers
- OR body was edited after labeling to remove intent markers
- OR gate fired then threshold bumped up so no paths are cited anymore

### Files to modify

- **EDIT:** `.agents/scripts/pulse-dispatch-large-file-gate.sh:654` (primary bug above — simple 4-line replacement)
- **EDIT:** `.agents/scripts/pulse-triage.sh:450-491` (`_reevaluate_simplification_labels` — SECONDARY continuation-comment parsing enhancement, ships in same PR)
  - After confirming the issue still carries `needs-simplification`, fetch the gate's sticky comment:
    - `gh issue view N --repo REPO --comments --json comments --jq '.comments[] | select(.body | contains("<!-- large-file-gate -->")) | .body'`
    - If no gate comment, preserve existing behaviour (return without clearing)
  - Parse the comment for continuation references matching `Simplification issues: #(\d+) (recently-closed — continuation)`
  - For each cited continuation issue N:
    - `gh issue view N --repo REPO --json state,labels,body`
    - If state is `OPEN` → citation is valid (work in progress), preserve label
    - If state is `CLOSED`:
      - If labels contain `simplification-incomplete` (from Fix D, t2169) → citation is stale
      - Else: parse body for target-file path, run `wc -l` via `_large_file_gate_verify_prior_reduced_size` (source the module). If file >= threshold → stale. If file < threshold OR file unresolvable → treat as valid (conservative).
  - If ALL cited continuations are stale, remove `needs-simplification`:
    - `gh issue edit N --repo REPO --remove-label needs-simplification`
    - Log: `[pulse-triage] Cleared stale needs-simplification on #N (all cited continuations phantom; next dispatch will re-evaluate the gate)`
  - If ANY citation is valid or unresolvable, preserve label
- **REUSE:** source `_large_file_gate_verify_prior_reduced_size` from `pulse-dispatch-large-file-gate.sh` rather than duplicating the `wc -l` + threshold logic. Add a source-guard at the top of the new code path.

### Reference patterns

- Function structure: existing `_reevaluate_simplification_labels` at line 450-491 (reads/writes labels via `gh issue edit`)
- Comment-parsing style: grep/sed piping on `gh issue view --json comments`
- Module sourcing: existing `source` guards in `pulse-triage.sh` for other helper modules
- Tests: adapt pattern from `test-large-file-gate-continuation-verify.sh` — stub `gh issue view` responses for cited continuations, assert label state on reeval

### Verification

```bash
# Unit test: stale continuation (closed + over-threshold file) → label cleared
bash .agents/scripts/tests/test-reeval-stale-continuation.sh

# Unit test: valid continuation (closed + under-threshold file) → label preserved
# (same test file, additional assertion)

# Unit test: no gate comment → label preserved (safe fallback)
# Unit test: open continuation → label preserved (work in progress)
# Unit test: simplification-incomplete short-circuit → label cleared without wc-l

# Manual dry-run against GH#19415 (once t2168 + t2169 also in place)
bash .agents/scripts/pulse-triage.sh --reeval-only 19415
```

## Acceptance criteria

- [ ] **PRIMARY:** `_issue_targets_large_files` auto-clears `needs-simplification` when extraction is empty AND issue is labeled (line 654 fix)
- [ ] **PRIMARY:** Regression test: stub empty-body issue labeled `needs-simplification`, assert label cleared after one reeval cycle
- [ ] `_reevaluate_simplification_labels` parses gate sticky comment for continuation refs
- [ ] Stale continuations (closed + over-threshold) trigger label clearance
- [ ] Valid continuations (closed + under-threshold) preserve label
- [ ] Open continuations preserve label (work in progress signal)
- [ ] `simplification-incomplete` label (from Fix D) short-circuits the `wc -l` check
- [ ] Missing gate comment preserves label (safe fallback)
- [ ] Regression tests cover all 5 continuation cases above

## Out of scope

- Parsing the gate comment format beyond the documented `Simplification issues: #N (recently-closed — continuation)` pattern. If the gate's comment format changes, update Fix E in lockstep.
- Clearing `needs-simplification` for reasons OTHER than stale continuation (e.g., gate threshold change, false-positive detection) — those belong in the gate itself.
- Automatic dispatch re-queue after label clearance — the next pulse cycle picks up the unblocked issue naturally.

## PR Conventions

Leaf child of `parent-task` #19482. PR body MUST use `For #19482` (NOT `Closes`/`Resolves`). `Resolves #19499` closes this leaf issue when the PR merges.

**This is the final child of t2163.** If t2168, t2169, and this PR (t2170) are the last three outstanding, the LAST of them to merge should use `Closes #19482` to close the parent. If this PR merges first among the three, use `For #19482`. If this PR merges last, use `Closes #19482`.

Depends on t2169 (Fix D) landing first — the `simplification-incomplete` label short-circuit references the label that Fix D creates. If t2169 is still in flight when this work starts, stub the short-circuit as a TODO and coordinate merge order.
