<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2168: split overloaded `simplification-debt` label — Fix C of t2163

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:interactive (Claude Sonnet 4.7)
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** t2163 / GH#19482 (5-fix plan)
- **Conversation context:** Filed after t2164 (Fixes A+B, PR #19484) merged. Closes the third root cause of the GH#19415 phantom-continuation pattern: the `simplification-debt` label is produced by two independent systems (daily function-complexity scan and large-file gate) with no way to tell them apart. Even with Fix B's `wc -l` verification, the basename+label dedup still conflates the two problem classes when one producer's closed issue lands within the other's 30-day reopen window.

## What

Rename the overloaded `simplification-debt` label into two distinct labels:

- **`file-size-debt`** — produced by the large-file gate (`pulse-dispatch-large-file-gate.sh`) when a target file exceeds `LARGE_FILE_LINE_THRESHOLD` (2000 lines).
- **`function-complexity-debt`** — produced by the daily function-complexity scan when a function exceeds 100 lines.

Update all producers, dedup queries, consumers (pulse-triage clear paths, label-sync, workflow refs), and migrate existing open `simplification-debt` issues to the appropriate split label based on title pattern.

## Why

Fix B (already merged in t2164) verifies file size at gate time before citing continuation. But the underlying label collision remains: the gate's dedup at `_large_file_gate_find_existing_debt_issue` queries for `simplification-debt` and matches on basename + 30-day window. A recently-closed function-complexity PR for `foo.sh` gets cited as "continuation" when the file-size gate next evaluates `foo.sh`, because both producers write to the same label namespace.

Fix B catches the mis-citation via `wc -l` — but only after the dedup match has already happened. With split labels, the dedup query itself becomes correct: the gate asks "is there an open `file-size-debt` for this basename?" and never sees function-complexity tickets. Fix B remains as defense-in-depth; Fix C removes the collision at the source.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Cross-file rename (2-3 producer files + migration script), dedup query updates in multiple queries, and a one-shot migration of existing issues. Narrative brief with file+line references. Not `tier:simple` because the producer discovery requires grepping across `.agents/scripts/` and the migration needs title-pattern classification. Not `tier:thinking` because no novel design — the new label names and their semantics are already decided here.

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-dispatch-large-file-gate.sh`
  - `_large_file_gate_file_new_debt_issue` (~line 390-443): rename `simplification-debt` → `file-size-debt` in the title, label string, and `gh label create` call
  - `_large_file_gate_find_existing_debt_issue` (~line 345-382): change `--label "simplification-debt"` → `--label "file-size-debt"` in both `gh issue list` calls (open + closed)
  - `_large_file_gate_apply` (~line 520-578): update `gh label create` pre-creation and any label-reference strings
  - `_large_file_gate_precheck_labels` (~line 42-137): existing `needs-simplification` handling is unaffected, but if any reference to `simplification-debt` appears in the comment/label logic, update it
- **EDIT:** whichever helper files the daily function-complexity scan issues
  - Discover: `rg -l 'simplification-debt' .agents/scripts/ .github/workflows/`
  - Likely candidates: `complexity-regression-helper.sh`, daily scan workflow, any `*-simplif*` helpers
  - Rename `simplification-debt` → `function-complexity-debt` in all producer code paths
- **EDIT:** consumers that read the label
  - `.agents/scripts/pulse-triage.sh` lines 55-60, 79-84, 511 (from `rg` output earlier)
  - Any label-sync or workflow that checks for `simplification-debt`
- **NEW:** `.agents/scripts/migrate-simplification-debt-labels.sh`
  - Takes `--repo SLUG` (default: current repo)
  - Takes `--dry-run` flag
  - Queries all OPEN issues with `simplification-debt` label
  - Pattern-matches each title:
    - Title starts with `simplification-debt:` and contains `exceeds N lines` → add `file-size-debt`, remove `simplification-debt`
    - Title starts with `simplification:` and contains `reduce function complexity` → add `function-complexity-debt`, remove `simplification-debt`
    - Otherwise → skip with warning (requires manual triage)
  - Prints a summary: N relabeled, M skipped, detail list
  - Idempotent: safe to re-run (skip issues that already have the new label)

### Reference patterns

- Dedup query style: `_large_file_gate_find_existing_debt_issue` (gh issue list with `--label` + `--search`)
- Label-create style: existing `gh label create ... --force` pattern at `_large_file_gate_file_new_debt_issue:404-408`
- Migration script pattern: follow the style of `.agents/scripts/issue-sync-helper.sh` label-sync logic (gh issue list + per-issue edit)
- Tests: adapt `test-large-file-gate-extract-edit-only.sh` and `test-large-file-gate-continuation-verify.sh` — stub `gh issue list --label file-size-debt` queries and assert the new label names appear in create calls

### Verification

```bash
# Producers no longer reference old label
rg 'simplification-debt' .agents/scripts/ .github/workflows/ | grep -v 'migrate-simplification-debt-labels.sh\|CHANGELOG\|t2168' | wc -l  # should be 0

# Migration dry-run
.agents/scripts/migrate-simplification-debt-labels.sh --repo marcusquinn/aidevops --dry-run

# Existing gate tests still green
bash .agents/scripts/tests/test-large-file-gate-extract-edit-only.sh
bash .agents/scripts/tests/test-large-file-gate-continuation-verify.sh
```

## Acceptance criteria

- [ ] `simplification-debt` label no longer used by any producer (ripgrep confirms)
- [ ] `file-size-debt` label in use by `pulse-dispatch-large-file-gate.sh`
- [ ] `function-complexity-debt` label in use by function-complexity scan
- [ ] `migrate-simplification-debt-labels.sh` exists and relabels existing open issues correctly in dry-run and live mode
- [ ] Existing gate regression tests updated to assert new label names and still pass
- [ ] New regression test: `test-migration-simplification-labels.sh` covers file-size, function-complexity, and ambiguous-title cases

## Out of scope

- Deprecating the `simplification-debt` label on GitHub itself (leave it around for audit trail of already-closed issues)
- Changing `LARGE_FILE_LINE_THRESHOLD` or the function-complexity 100-line threshold
- Reworking the daily complexity scan's scheduling or scope

## PR Conventions

Leaf child of `parent-task` #19482. PR body MUST use `For #19482` (NOT `Closes`/`Resolves`). `Resolves #19497` closes this leaf issue when the PR merges. Only the FINAL phase child (the last of Fixes C/D/E to merge) uses `Closes #19482`.
