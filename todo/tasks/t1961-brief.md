---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1961: refactor dispatch-dedup-helper is_assigned — extract _has_active_claim() to fix complexity ratchet

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (follow-up to GH#18352 / PR #18353)
- **Created by:** marcusquinn (human, interactive)
- **Parent task:** GH#18352
- **Conversation context:** PR #18353 was merged manually despite the Complexity
  Analysis CI check failing. The fix (added `status:claimed` and
  `origin:interactive` to the active-claim signal in `is_assigned()`) bloated
  the function to 101 lines — one line over the 100-line function size cap,
  pushing `func` violations from 40 to 41 and breaking the complexity ratchet.
  Every subsequent PR CI run will now fail Complexity Analysis until this is
  resolved. This is a surgical refactor, not a behaviour change.

## What

Extract the two inline `jq` label queries inside `is_assigned()` into a new
private helper `_has_active_claim()` that takes the issue metadata JSON and
returns `"true"` when any of `status:queued`, `status:in-progress`,
`status:in-review`, `status:claimed`, or `origin:interactive` is present.
Replace the two local variables (`has_active_status`, `has_origin_interactive`)
and their combined check with a single `active_claim` variable populated from
`_has_active_claim()`. This preserves GH#18352 behaviour exactly while dropping
`is_assigned()` from 101 lines to ~89 lines, bringing `func` violations from
41 back to 40 (at threshold).

## Why

- CI is currently broken on main: `complexity-scan-helper.sh ratchet-check`
  reports `func:41` against a threshold of 40, and the Complexity Analysis
  workflow will fail on every PR until this is fixed.
- The extraction also improves readability: the 208-character jq query on line
  680 of `dispatch-dedup-helper.sh` is hard to reason about inline, and the
  named helper makes the full active-claim lifecycle explicit in one place.
- No behaviour change — all 16 existing `is_assigned()` tests must still pass.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (just `dispatch-dedup-helper.sh`)
- [x] **Complete code blocks for every edit?** (exact oldString/newString below)
- [x] **No judgment or design decisions?** (mechanical extraction)
- [x] **No error handling or fallback logic to design?** (existing fallback preserved verbatim)
- [x] **Estimate 1h or less?** (~15 minutes including verification)
- [x] **4 or fewer acceptance criteria?** (3 criteria)

All checked = `tier:simple`.

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file mechanical refactor with exact oldString/newString
edits provided. No design decisions — the helper signature, body, and call site
changes are all verbatim below. Verification is deterministic (shellcheck +
existing test harness + complexity-scan-helper.sh ratchet-check).

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/dispatch-dedup-helper.sh` — add `_has_active_claim()`
  helper above `is_assigned()`, replace the two label-check blocks inside
  `is_assigned()` with a single call to the new helper.

### Implementation Steps

1. Insert `_has_active_claim()` immediately above the `is_assigned()` function
   header (the `#######################################` block starting around
   line 610).

2. Inside `is_assigned()`, replace lines 672-687 (the `has_active_status` and
   `has_origin_interactive` declarations and jq calls) with a single
   `active_claim` line calling `_has_active_claim "$issue_meta_json"`.

3. Update the owner/maintainer exemption check at lines 702-707 to use
   `[[ "$active_claim" != "true" ]]` instead of the compound
   `[[ "$has_active_status" != "true" && "$has_origin_interactive" != "true" ]]`
   check.

### Verification

```bash
cd ~/Git/aidevops.chore-t1961-is-assigned-complexity-refactor
shellcheck .agents/scripts/dispatch-dedup-helper.sh
bash .agents/scripts/tests/test-dispatch-dedup-helper-is-assigned.sh
~/.aidevops/agents/scripts/complexity-scan-helper.sh ratchet-check
```

Expected: shellcheck exits 0, all 16 tests pass, complexity-scan reports
`func:40` (at threshold, not over).

## Acceptance Criteria

- [ ] `shellcheck .agents/scripts/dispatch-dedup-helper.sh` exits 0
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/dispatch-dedup-helper.sh"
  ```
- [ ] All 16 `is_assigned()` tests pass
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dispatch-dedup-helper-is-assigned.sh"
  ```
- [ ] Complexity ratchet shows `func:40` (not 41)
  ```yaml
  verify:
    method: bash
    run: "~/.aidevops/agents/scripts/complexity-scan-helper.sh ratchet-check 2>&1 | grep -E 'Actual violations.*func:40 '"
  ```

## Context & Decisions

- **Why extract rather than inline one-liner compression:** A single compound
  jq expression would save lines but would be even less readable than the
  current two-query form. A named helper documents the semantic (what does
  "active claim" mean?) and makes future additions (new status labels) a
  one-line change.
- **Why not lower the complexity threshold instead:** The framework policy
  treats function size >100 as a ratchet metric, not a soft warning. The
  function genuinely is too long; shrinking it is the correct fix.
- **Non-goal:** no behaviour change. The new helper must return `"true"` for
  exactly the same set of issue states as the previous inline checks. Tests
  enforce this.

## Relevant Files

- `.agents/scripts/dispatch-dedup-helper.sh:640-741` — `is_assigned()`
- `.agents/scripts/dispatch-dedup-helper.sh:672-687` — the inline jq blocks to replace
- `.agents/scripts/dispatch-dedup-helper.sh:702-707` — the owner/maintainer exemption check to update
- `.agents/scripts/tests/test-dispatch-dedup-helper-is-assigned.sh` — 16 tests that must all still pass
- `.agents/scripts/complexity-scan-helper.sh` — `ratchet-check` subcommand for local verification

## Dependencies

- **Blocked by:** none (main is already on the #18353 merge commit)
- **Blocks:** every future PR into main (CI will fail Complexity Analysis until resolved)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | done | already mapped in the parent session |
| Implementation | 10m | mechanical extract-method refactor |
| Testing | 5m | existing harness + ratchet-check |
| **Total** | **~15m** | |
