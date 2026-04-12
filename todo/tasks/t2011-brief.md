---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2011: issue-sync: add `auto-dispatch` to protected label list — stop reconciliation from stripping it

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) via ai-interactive
- **Conversation context:** Observed in this session's t1992 (#18418) timeline that the `auto-dispatch` label was added manually via `gh issue edit`, then **stripped** by the next issue-sync run (because the TODO entry didn't yet carry `#auto-dispatch`), then re-added several minutes later when the retag commit landed. This created a 7-minute window where the issue was invisible to the pulse. The user asked me to "log those todos and detailed plans" for the follow-ups noted at the end of t1996/t1997 — this is one of them.

## What

Add `auto-dispatch` to the exact-match protected label list in `_is_protected_label()` at `.agents/scripts/issue-sync-helper.sh:130-136`. One-line addition. Once protected, the reconciliation pass at `_reconcile_labels()` (line 161) will skip it instead of removing it when the TODO entry doesn't carry the matching `#auto-dispatch` tag.

## Why

The reconciliation logic at line 161 follows this rule: for each current label on the issue, if it's not protected and not in the desired set derived from TODO tags, remove it. The `_is_protected_label()` function at line 123 already has a prefix list (`status:*`, `origin:*`, `tier:*`, `source:*`) and an exact-match list (`persistent`, `needs-maintainer-review`, `parent-task`, `meta`, etc.) — but `auto-dispatch` is in neither. Since `auto-dispatch` has no `:` separator, `_is_tag_derived_label()` returns true, so reconciliation considers it removable.

Concrete repro from this session (#18418 t1992 timeline):

```text
21:03:11Z labeled auto-dispatch        ← my manual gh issue edit
21:03:19Z labeled stats                ← issue-sync added (TODO has #stats)
21:03:21Z unlabeled auto-dispatch      ← issue-sync REMOVED (TODO had #interactive, not #auto-dispatch)
...
21:10:26Z labeled auto-dispatch        ← issue-sync re-added (after my retag commit landed)
```

The 7-minute strip window (21:03:21Z → 21:10:26Z) is exactly the problem the user flagged: manually-managed dispatch state shouldn't be at the mercy of TODO-tag reconciliation.

The fix is minimal: `auto-dispatch` is a manually-managed dispatch flag (set by humans, by other workflows, or by the pulse itself for backfill/auto-claim flows) — it should never be removed by tag reconciliation. Adding it to the protected exact-match list makes it stable across issue-sync passes. If the user wants to undispatch an issue, they remove the label explicitly via `gh issue edit --remove-label auto-dispatch`, not via TODO tag editing.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** → yes (issue-sync-helper.sh + test)
- [x] **Complete code blocks for every edit?** → yes (one-line addition + 1 fixture test)
- [x] **No judgment or design decisions?** → yes (the fix is mechanical; placement in the existing list)
- [x] **No error handling or fallback logic to design?** → yes (no new failure modes)
- [x] **Estimate 1h or less?** → yes (~30m)
- [x] **4 or fewer acceptance criteria?** → yes (3 criteria)

**Selected tier:** `tier:simple`

**Tier rationale:** Single-line fix in a known location with known semantics. Trivial test fixture. Pure addition to an existing allow-list. Haiku-friendly.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/issue-sync-helper.sh:130-136` — add `auto-dispatch` to the exact-match protected label list.
- `EDIT: .agents/scripts/tests/test-issue-sync-helper.sh` (or whichever test file already covers `_is_protected_label` and `_reconcile_labels`) — add a regression test asserting that `auto-dispatch` survives a reconciliation pass when the desired label set does not include it.

### Implementation Steps

1. **Edit `_is_protected_label()`** at line 130-136. The current exact-match block is:

   ```bash
   case "$lbl" in
   persistent | needs-maintainer-review | not-planned | duplicate | wontfix | \
       already-fixed | "good first issue" | "help wanted" | \
       parent-task | meta)
       return 0
       ;;
   esac
   ```

   Change to:

   ```bash
   case "$lbl" in
   persistent | needs-maintainer-review | not-planned | duplicate | wontfix | \
       already-fixed | "good first issue" | "help wanted" | \
       parent-task | meta | auto-dispatch)
       return 0
       ;;
   esac
   ```

   That's it for the production code change.

2. **Add regression test.** First locate the existing test file that covers `_is_protected_label` and `_reconcile_labels`:

   ```bash
   rg -l '_is_protected_label\|_reconcile_labels' .agents/scripts/tests/
   ```

   If no test file exists for this function specifically, create `.agents/scripts/tests/test-issue-sync-protected-labels.sh` with the standard aidevops test harness pattern. Test cases:

   ```bash
   test_auto_dispatch_is_protected() {
       # _is_protected_label "auto-dispatch" must return 0
       if _is_protected_label "auto-dispatch"; then
           print_result "auto-dispatch is in protected list" 0
       else
           print_result "auto-dispatch is in protected list" 1 \
               "_is_protected_label auto-dispatch returned non-zero (not protected)"
       fi
   }

   test_reconcile_skips_auto_dispatch() {
       # Set up: stub `gh` to return labels including auto-dispatch
       # Call _reconcile_labels with desired set NOT containing auto-dispatch
       # Assert: auto-dispatch is NOT in the to_remove set
       # (Implementation: capture gh issue edit calls via the stub and assert
       #  no `--remove-label auto-dispatch` is invoked)
   }
   ```

3. **Manual smoke test:**

   ```bash
   # In an issue with auto-dispatch already applied:
   gh issue edit <num> --add-label auto-dispatch
   # Push a TODO entry without #auto-dispatch and let issue-sync run
   # Verify: auto-dispatch is still on the issue afterwards
   ```

### Verification

```bash
shellcheck .agents/scripts/issue-sync-helper.sh
shellcheck .agents/scripts/tests/test-issue-sync-protected-labels.sh
bash .agents/scripts/tests/test-issue-sync-protected-labels.sh
# Existing characterization tests
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
```

## Acceptance Criteria

- [ ] `_is_protected_label "auto-dispatch"` returns 0 (protected).
  ```yaml
  verify:
    method: codebase
    pattern: "auto-dispatch\\)"
    path: ".agents/scripts/issue-sync-helper.sh"
  ```
- [ ] Regression test `test-issue-sync-protected-labels.sh` (or extension of an existing test file) covers both `_is_protected_label("auto-dispatch")` returning 0 and `_reconcile_labels` skipping `auto-dispatch` removal even when the desired set excludes it.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-issue-sync-protected-labels.sh 2>/dev/null || rg -l '_is_protected_label.*auto-dispatch' .agents/scripts/tests/"
  ```
- [ ] `shellcheck` clean on touched files.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/issue-sync-helper.sh"
  ```

## Context & Decisions

- **Why protect rather than fix the desired-set computation:** there are multiple sources that can add `auto-dispatch` (human via `gh issue edit`, the pulse self-claiming an issue for backfill, the post-merge-review-scanner from t1993, GH Action workflows). All of these are intentional dispatch state and shouldn't be subject to TODO-tag reconciliation. Protecting the label is simpler and matches the existing pattern for `parent-task` (also manually-set, also protected).
- **Why not also protect other dispatch-related labels:** `status:*` is already protected via the prefix rule. `origin:*` is already protected. `tier:*` is already protected. `auto-dispatch` is the only manually-managed dispatch flag NOT yet covered.
- **No risk of state drift:** if a TODO entry has `#auto-dispatch`, the sync will still ADD `auto-dispatch` (idempotent). Protecting only blocks REMOVAL. So the desired flow ("add #auto-dispatch tag → label appears on issue") still works.
- **Ruled out:** rewriting the reconciliation algorithm. Single-line fix is sufficient.

## Relevant Files

- `.agents/scripts/issue-sync-helper.sh:118-138` — `_is_protected_label()` definition
- `.agents/scripts/issue-sync-helper.sh:140-152` — `_is_tag_derived_label()` (related, no change needed)
- `.agents/scripts/issue-sync-helper.sh:161-201` — `_reconcile_labels()` (the consumer)
- Concrete repro: #18418 (t1992) timeline showing the strip-restore at 21:03:21Z and 21:10:26Z

## Dependencies

- **Blocked by:** none
- **Blocks:** none directly; eliminates a window-of-vulnerability for dispatch state

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Edit `_is_protected_label()` (single line) | 2m | |
| Locate existing test file or create new one | 5m | |
| Write 2 test cases (function-level + integration via stub) | 15m | |
| Shellcheck + run tests | 5m | |
| Manual smoke test on a sandbox issue | 5m | |
| **Total** | **~30m** | |
