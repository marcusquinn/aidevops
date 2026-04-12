---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2012: issue-sync: tier label addition source fix — parse `**Selected tier:**` line + replace existing tier:* labels

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) via ai-interactive
- **Conversation context:** While retagging t1993 (#18420) for worker dispatch, observed that the issue ended up with both `tier:simple` and `tier:standard` labels. Filed t1997 as a downstream cleanup (GitHub Action removes duplicates, dispatcher picks highest). This task is the **source fix**: prevent issue-sync from adding a second tier label in the first place. Combined with t1997, the tier label collision class is closed at both ends (source + cleanup + dispatcher fallback).

## What

Two related fixes in `issue-sync-lib.sh` and `issue-sync-helper.sh`:

1. **`_extract_tier_from_brief()` parses the `**Selected tier:**` line, not the whole brief.** The current implementation at `issue-sync-lib.sh:1322` does `grep -oE 'tier:(simple|standard|reasoning)' "$brief_path" | head -1` — it grabs the FIRST tier mention anywhere in the brief. But the brief template's tier-checklist text includes phrases like "use `tier:standard` or higher" and "rank order: tier:reasoning > tier:standard > tier:simple", so `head -1` returns whatever appears first textually, not the explicit selection. Fix: parse the line `**Selected tier:** \`tier:XXX\`` specifically.

2. **Tier label addition replaces, not appends.** When issue-sync determines the desired tier label and the issue already has a `tier:*` label, the addition path (at `issue-sync-helper.sh:541-550` and `:684-693`) appends without removing the old one. Combined with `_is_protected_label("tier:*") = true`, the old label survives reconciliation, leaving both. Fix: when adding a `tier:*` label, first remove any other `tier:*` labels currently on the issue.

## Why

Concrete repro from this session — issue #18420 (t1993) timeline:

```text
20:58:00Z labeled tier:simple        ← from `gh issue create --label "...,tier:simple,..."`
21:03:26Z labeled tier:standard      ← added by issue-sync after retag commit landed
```

My t1993 brief had:

```markdown
### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** → yes (Option A...)
- [x] **Complete code blocks for every edit?** → yes...
- [ ] **No judgment or design decisions?** → no (Option A vs B requires reading...)
- [x] **No error handling or fallback logic to design?** → yes
- [x] **Estimate 1h or less?** → yes (~45m)
- [ ] **4 or fewer acceptance criteria?** → no (6 criteria)

**Selected tier:** `tier:simple`
```

Two unchecked boxes. The `_validate_tier_checklist()` function at `issue-sync-lib.sh:1338-1359` correctly detected this and overrode the selection from `tier:simple` → `tier:standard`. **That's correct behaviour** — the validator did its job.

The bug is in what happens NEXT:

1. Issue creation step set `tier:simple` (from my manual `--label tier:simple` in the `gh issue create` call).
2. Issue-sync ran on the next TODO push, called `_extract_tier_from_brief()`, validator overrode to `tier:standard`, issue-sync ADDED `tier:standard` to the issue.
3. The existing `tier:simple` was protected from removal by `_is_protected_label("tier:*")` (line 127 of `issue-sync-helper.sh`), so it stayed.
4. Result: both labels coexist.

The protection rule was correct for the case it was designed for (manually-set tiers shouldn't be reconciled away). But it interacts badly with the validator's override path because the validator's REPLACE intent isn't carried through to actual label state — only the additive operation runs.

The fragility of `_extract_tier_from_brief()` is a separate but related issue: even without the validator interaction, a brief that mentions `tier:standard` in commentary text BEFORE the actual `**Selected tier:**` line will return the wrong tier. The grep-anywhere approach is too loose for what should be a structured field extraction.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** → yes (`issue-sync-lib.sh` + `issue-sync-helper.sh` + 1 test = arguably 3 but the test is straightforward)
- [x] **Complete code blocks for every edit?** → yes (sed pattern + replace logic skeletons below)
- [x] **No judgment or design decisions?** → yes (parser + replace-vs-append are mechanical fixes)
- [x] **No error handling or fallback logic to design?** → yes (fall back to `head -1` grep when `**Selected tier:**` line not found)
- [x] **Estimate 1h or less?** → yes (~1h)
- [x] **4 or fewer acceptance criteria?** → yes (4 criteria)

**Selected tier:** `tier:simple`

**Tier rationale:** Two small targeted fixes in well-understood locations with concrete file:line references. Pattern parsing + label-state-aware addition. Both have full code skeletons in this brief. Test fixture uses my actual t1993-brief.md which exhibits the bug. Haiku-friendly mechanical implementation.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/issue-sync-lib.sh:1313-1324` — rewrite `_extract_tier_from_brief()` to parse the `**Selected tier:**` line first, falling back to grep-anywhere only if the structured line is missing.
- `EDIT: .agents/scripts/issue-sync-helper.sh:541-550` and `:684-693` — when applying a tier label, first remove any pre-existing `tier:*` labels on the target issue. Two near-identical sites; deduplicate into a helper.
- `NEW: .agents/scripts/tests/test-issue-sync-tier-extraction.sh` — fixture-based test using the actual t1993-brief.md (now committed under todo/tasks/) and a synthetic brief with multiple tier mentions in the wrong order.

### Implementation Steps

1. **Rewrite `_extract_tier_from_brief()`** at `issue-sync-lib.sh:1313-1324`. Replace:

   ```bash
   _extract_tier_from_brief() {
       local brief_path="$1"
       if [[ ! -f "$brief_path" ]]; then
           return 0
       fi
       # Extract tier from "**Selected tier:** `tier:XXX`" line
       grep -oE 'tier:(simple|standard|reasoning)' "$brief_path" | head -1 || true
       return 0
   }
   ```

   With:

   ```bash
   _extract_tier_from_brief() {
       local brief_path="$1"
       if [[ ! -f "$brief_path" ]]; then
           return 0
       fi

       # PRIMARY: parse the explicit `**Selected tier:**` line.
       # The brief template requires this exact prefix; search for it
       # specifically rather than grepping anywhere in the document
       # (which catches commentary text like "use tier:standard or higher").
       local selected_line
       selected_line=$(grep -m1 -E '^\*\*Selected tier:\*\*' "$brief_path" 2>/dev/null || true)
       if [[ -n "$selected_line" ]]; then
           local tier
           tier=$(printf '%s' "$selected_line" | grep -oE 'tier:(simple|standard|reasoning)' | head -1)
           if [[ -n "$tier" ]]; then
               printf '%s' "$tier"
               return 0
           fi
       fi

       # FALLBACK: grep-anywhere for briefs that don't follow the template.
       # Logged as a warning so we can chase non-conforming briefs.
       local fallback
       fallback=$(grep -oE 'tier:(simple|standard|reasoning)' "$brief_path" 2>/dev/null | head -1 || true)
       if [[ -n "$fallback" ]]; then
           echo "[WARN] _extract_tier_from_brief: brief at $brief_path missing **Selected tier:** line, falling back to first tier mention ($fallback)" >&2
           printf '%s' "$fallback"
       fi
       return 0
   }
   ```

2. **Add `_apply_tier_label_replace()`** helper near the existing label functions in `issue-sync-helper.sh` (e.g., right after `_gh_edit_labels`). When called, it first finds any existing `tier:*` labels on the issue and removes them, then applies the new tier label:

   ```bash
   # _apply_tier_label_replace: set the tier label on an issue, replacing any
   # existing tier:* labels. Avoids the collision class observed in t1997 where
   # multiple tier:* labels could coexist when issue-sync added a new tier
   # without removing old ones (and the protected-prefix rule prevented
   # _reconcile_labels from cleaning up the old one).
   #
   # Arguments:
   #   $1 - repo slug
   #   $2 - issue number
   #   $3 - new tier label (e.g., tier:standard)
   _apply_tier_label_replace() {
       local repo="$1" num="$2" new_tier="$3"
       [[ -z "$repo" || -z "$num" || -z "$new_tier" ]] && return 0

       local existing_tiers
       existing_tiers=$(gh issue view "$num" --repo "$repo" --json labels \
           --jq '[.labels[].name | select(startswith("tier:"))] | join(",")' 2>/dev/null || echo "")

       # Remove any existing tier labels that don't match the new one
       if [[ -n "$existing_tiers" ]]; then
           local -a remove_args=()
           local _saved_ifs="$IFS"
           IFS=','
           for old in $existing_tiers; do
               [[ -z "$old" ]] && continue
               [[ "$old" == "$new_tier" ]] && continue
               remove_args+=("--remove-label" "$old")
           done
           IFS="$_saved_ifs"
           if [[ ${#remove_args[@]} -gt 0 ]]; then
               gh issue edit "$num" --repo "$repo" "${remove_args[@]}" 2>/dev/null || \
                   print_warning "tier replace: failed to remove old tier label(s) from #$num in $repo"
           fi
       fi

       # Add the new tier label (idempotent)
       gh issue edit "$num" --repo "$repo" --add-label "$new_tier" 2>/dev/null || true
       return 0
   }
   ```

3. **Wire `_apply_tier_label_replace()` into the two existing tier-label sites.** Find both occurrences via:

   ```bash
   rg -n 'tier_label.*labels=|labels.*tier_label' .agents/scripts/issue-sync-helper.sh
   ```

   The current code at `:541-550` and `:684-693` looks like:

   ```bash
   if [[ -n "$tier_label" ]]; then
       tier_label=$(_validate_tier_checklist "$brief_path" "$tier_label")
       if [[ -n "$labels" ]]; then
           labels="${labels},${tier_label}"
       else
           labels="$tier_label"
       fi
   fi
   ```

   The labels variable is later used in a `gh issue edit ... --add-label "$labels"` style call. The issue is that this concatenation flow can't tell the caller "I'm replacing a tier label, remove the old one first". The cleanest refactor: separate the tier label from the rest of the labels and apply it via `_apply_tier_label_replace` after the main label set is applied. Skeleton:

   ```bash
   # Hold the tier label aside from the main labels list
   local tier_label=""
   tier_label=$(_extract_tier_from_brief "$brief_path")
   if [[ -n "$tier_label" ]]; then
       tier_label=$(_validate_tier_checklist "$brief_path" "$tier_label")
   fi

   # ... existing label application path (without the tier label) ...
   # gh issue edit ... --add-label "$labels"

   # Tier label gets the special replace-not-append treatment
   if [[ -n "$tier_label" ]]; then
       _apply_tier_label_replace "$repo" "$num" "$tier_label"
   fi
   ```

   Apply the same pattern at both call sites (lines 541 and 684).

4. **Regression test** at `.agents/scripts/tests/test-issue-sync-tier-extraction.sh`. Two test classes:

   **Class A: `_extract_tier_from_brief` parser correctness**

   ```bash
   test_extract_returns_selected_tier_not_first_mention() {
       local brief
       brief=$(mktemp)
       cat > "$brief" <<'BRIEF'
   ## Tier

   ### Tier checklist
   If any answer is "no", use `tier:standard` or higher. Rank order:
   `tier:reasoning` > `tier:standard` > `tier:simple`.

   - [x] all checks
   - [x] all checks

   **Selected tier:** `tier:simple`
   BRIEF
       local result
       result=$(_extract_tier_from_brief "$brief")
       rm -f "$brief"
       if [[ "$result" == "tier:simple" ]]; then
           print_result "extract returns Selected tier (not first mention in commentary)" 0
       else
           print_result "extract returns Selected tier (not first mention in commentary)" 1 \
               "expected tier:simple, got '$result'"
       fi
   }

   test_extract_falls_back_when_selected_line_missing() {
       # Brief without the **Selected tier:** marker — fallback to first tier mention
       local brief
       brief=$(mktemp)
       cat > "$brief" <<'BRIEF'
   ## Estimate
   tier:standard for this work.
   BRIEF
       local result
       result=$(_extract_tier_from_brief "$brief" 2>/dev/null)
       rm -f "$brief"
       if [[ "$result" == "tier:standard" ]]; then
           print_result "extract falls back to first mention when **Selected tier:** missing" 0
       else
           print_result "extract falls back to first mention when **Selected tier:** missing" 1 \
               "expected tier:standard, got '$result'"
       fi
   }

   test_extract_handles_actual_t1993_brief_repro() {
       # Use the real t1993 brief which mentions tier:standard in checklist text
       # before the **Selected tier:** tier:simple line. This is the canonical
       # repro case from this session.
       local brief="$REPO_ROOT/todo/tasks/t1993-brief.md"
       [[ ! -f "$brief" ]] && {
           print_result "t1993 brief repro fixture exists" 1 "missing $brief"
           return 0
       }
       local result
       result=$(_extract_tier_from_brief "$brief")
       if [[ "$result" == "tier:simple" ]]; then
           print_result "extract correctly handles t1993 brief (returns selected tier)" 0
       else
           print_result "extract correctly handles t1993 brief" 1 \
               "expected tier:simple, got '$result' — extractor still buggy"
       fi
   }
   ```

   **Class B: `_apply_tier_label_replace` removes existing tier labels**

   ```bash
   test_apply_tier_replace_removes_existing() {
       # Stub gh to:
       #   1. Return labels=[bug, tier:simple, auto-dispatch] on `gh issue view`
       #   2. Record `gh issue edit` calls
       # Call _apply_tier_label_replace "owner/repo" 123 "tier:standard"
       # Assert: a `--remove-label tier:simple` call was made before/with
       #         `--add-label tier:standard`
   }

   test_apply_tier_replace_noop_when_already_correct() {
       # Stub gh: labels already include tier:standard
       # Call with new_tier=tier:standard
       # Assert: no remove calls; only the (idempotent) add
   }
   ```

   Use a `gh` stub script written via heredoc, the same pattern as `test-consolidation-dispatch.sh` from t1982.

### Verification

```bash
shellcheck .agents/scripts/issue-sync-lib.sh \
  .agents/scripts/issue-sync-helper.sh \
  .agents/scripts/tests/test-issue-sync-tier-extraction.sh
bash .agents/scripts/tests/test-issue-sync-tier-extraction.sh

# Manual: re-process #18420 with the fixed extractor
# Should extract tier:standard from validator override and replace tier:simple
```

## Acceptance Criteria

- [ ] `_extract_tier_from_brief()` parses the `**Selected tier:**` line first, with grep-anywhere as a fallback.
  ```yaml
  verify:
    method: codebase
    pattern: "Selected tier:.*grep|selected_line"
    path: ".agents/scripts/issue-sync-lib.sh"
  ```
- [ ] `_apply_tier_label_replace()` exists and is invoked from both tier label application sites in `issue-sync-helper.sh`.
  ```yaml
  verify:
    method: codebase
    pattern: "_apply_tier_label_replace"
    path: ".agents/scripts/issue-sync-helper.sh"
  ```
- [ ] Regression test `test-issue-sync-tier-extraction.sh` passes with at least 5 assertions covering: selected-tier extraction, fallback when missing, the actual t1993 brief repro case, replace-removes-existing, and replace-no-op-when-correct.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-issue-sync-tier-extraction.sh"
  ```
- [ ] `shellcheck` clean on touched scripts.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/issue-sync-lib.sh .agents/scripts/issue-sync-helper.sh .agents/scripts/tests/test-issue-sync-tier-extraction.sh"
  ```

## Context & Decisions

- **Why both fixes in one task:** they're tightly coupled — the extractor returning the wrong tier and the labeller appending instead of replacing combine to produce the collision. Splitting them would require either (a) merging in two PRs that touch the same files, or (b) leaving the system half-broken between the two merges. Better to land them together.
- **Why parse `**Selected tier:**` first instead of replacing the grep entirely:** the brief template requires the explicit line and that should be the canonical signal. The grep fallback covers non-conforming briefs (legacy or hand-written ones) so we don't break their dispatch — but it warns to stderr so we can hunt them down.
- **Why `_apply_tier_label_replace()` calls `gh issue view` even though we already have label info upstream:** the upstream label info may be stale by the time we reach the label application path (race window between view and edit). Re-fetching ensures we don't accidentally remove a tier label that was just added by another concurrent process. Two API calls per tier change is acceptable; tier changes are infrequent.
- **Interaction with t1997:** t1997 (downstream cleanup) is the GitHub Action and the dispatcher fallback. This task (t2012) is the source fix. They're complementary:
  - t2012 prevents new collisions from being created by issue-sync.
  - t1997 cleans up any collisions that slip through (from other sources, race windows, manual edits).
  - Both should land. t2012 reduces the number of times t1997's Action has to fire.
- **Validator behaviour preserved:** `_validate_tier_checklist()` continues to override `tier:simple` → `tier:standard` when checklist boxes are unchecked. The override is correct; the bug was in how the result got applied.

## Relevant Files

- `.agents/scripts/issue-sync-lib.sh:1313-1324` — `_extract_tier_from_brief()` (parser fix)
- `.agents/scripts/issue-sync-lib.sh:1326-1363` — `_validate_tier_checklist()` (no change, but referenced)
- `.agents/scripts/issue-sync-helper.sh:541-550, 684-693` — tier label addition sites (replace-not-append fix)
- `.agents/scripts/issue-sync-helper.sh:118-138` — `_is_protected_label()` (already protects `tier:*`, no change)
- Concrete repro: `todo/tasks/t1993-brief.md` (the actual brief that triggered the collision)
- `gh issue list --repo marcusquinn/aidevops --state all --search "label:tier:simple label:tier:standard"` — find all currently-affected issues

## Dependencies

- **Blocked by:** none
- **Blocks:** none directly; t1997 is complementary, not blocking
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Rewrite `_extract_tier_from_brief()` parser | 15m | Selected-tier-line pattern + fallback |
| Write `_apply_tier_label_replace()` helper | 15m | gh view + remove + add |
| Wire helper into both call sites | 10m | Two near-identical edits |
| Write regression test (5+ assertions, gh stub) | 25m | Use t1993 brief as fixture |
| Shellcheck + run tests | 5m | |
| **Total** | **~1h** | |
