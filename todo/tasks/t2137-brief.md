<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2137 — fix(issue-sync): skip closing hygiene on parent-task issues + atomic status:done mutation

## Session Origin

Interactive session, 2026-04-16. Surfaced while merging PR #19228 (t2126 plan
PR). Observed two systemic defects in `.github/workflows/issue-sync.yml` that
affect every PR merge:

1. Parent-task issue #19222 received `status:done` despite PR using the
   `For #19222` keyword (t2046 parent-task convention), because the
   workflow's title-fallback `tNNN:` search ignored the `parent-task` label.
2. `status:done` was added and `status:in-review` was removed in two separate
   `gh issue edit` calls ~5 seconds apart — violates the atomicity contract
   the framework established in t2040 (`_mark_issue_done`) for the bash helper
   path, but the workflow was never updated to match.

## What

Two surgical edits to `.github/workflows/issue-sync.yml` `sync-on-pr-merge`
job, plus test coverage.

### Fix 1: skip parent-task issues in title-fallback

In the `find-issue` step (around line 335-358), after a title-based
`tNNN:` search returns a candidate issue, check whether that issue carries
the `parent-task` label. If yes, drop it from `found_issues` output with a
clear log line.

**Why title-fallback only, not the Closes/Fixes/Resolves path:** explicit
Closes/Fixes/Resolves on a parent-task is either (a) the legitimate terminal
phase closing the parent, or (b) already prevented by
`parent-task-keyword-check.yml`. Respecting the keyword is correct
behaviour in both cases. The title-fallback is the gap where intent is
ambiguous — a planning PR with title `t2126:` legitimately references the
parent but isn't closing it.

### Fix 2: atomic label mutation

In the `Apply closing hygiene` step (lines 443-450), collapse the 1
`--add-label` call + 7 `--remove-label` calls (8 sequential API calls) into
a single `gh issue edit` invocation with repeated flags.

GitHub's issue edit API supports multiple `--add-label` and `--remove-label`
on one call; the resulting `labeled`/`unlabeled` events carry identical
timestamps, closing the race window entirely.

### Test coverage

Extend `.agents/scripts/tests/test-label-invariants.sh` (or add a sibling
test) with a case that extracts the gh invocation list from the workflow
yaml (by parsing the `Apply closing hygiene` step) and asserts exactly one
`gh issue edit` call in the status-mutation block.

## Why

- Every parent-task planning PR has silently flipped its parent to
  `status:done` since parent-task convention was introduced. Parents with
  verification work still to do are incorrectly categorised, affecting
  triage, dispatch dedup, and the status-label state machine. Observed on
  #19222 after PR #19228 merged — all 5 children coincidentally closed too,
  so the false positive wasn't caught earlier.
- The non-atomic window is narrow (5s observed) but arbitrary under API
  latency; t2040's own code comment explicitly warns *"the reconciler's
  label-invariant pass would see two status labels and could pick the wrong
  survivor, potentially losing `done`"*. The framework already acknowledges
  this as a known risk class.
- Duplicated logic between the bash helper and the workflow is the root
  cause of the divergence — t2040 fixed one copy, the other drifted.

## How

### Files to modify

- **EDIT:** `.github/workflows/issue-sync.yml`
  - Lines ~335-358 (`find-issue` step): add parent-task label probe before
    writing `found_issues` output.
  - Lines ~443-450 (label mutation block): collapse to one `gh issue edit`
    call.
- **NEW or EDIT:** `.agents/scripts/tests/test-label-invariants.sh` (or
  new `test-workflow-label-atomicity.sh`): assert single-edit invariant.

### Reference patterns

- **Existing skip-hygiene pattern:** lines 384-402 in the same file
  (`IS_REJECTED` path for rejection labels — `invalid`, `not-planned`,
  `wontfix`, `duplicate`). My parent-task skip follows the identical shape.
  Prior art: PR #17986 established this pattern.
- **Atomic bash helper:** `_mark_issue_done` → `set_issue_status` in
  `.agents/scripts/issue-sync-helper.sh:374`. Do not call this from the
  workflow (requires sourcing the whole helper); instead inline a single
  `gh issue edit` with the equivalent flag set.

### Verification

- **Shellcheck:** `shellcheck .github/workflows/issue-sync.yml` (via
  `actionlint` if available; otherwise the embedded `run:` blocks should
  pass manual review).
- **Test:** `bash .agents/scripts/tests/test-label-invariants.sh` must
  remain green; new workflow-atomicity test must assert single-edit invariant.
- **Dry-run reasoning:** trace the workflow logic against the t2126/19228
  scenario — parent-task issue #19222 with `For #19222` should produce
  `LINKED_ISSUES=""`, `FOUND_ISSUES=""` (because parent-task skip), therefore
  `ALL_ISSUES=""`, therefore early exit at line 376-378. No comment, no label
  mutation. Correct.

## Acceptance criteria

- [ ] Parent-task issue with `For #NNN`-only PR merge does NOT receive
  `status:done` label or "Completed via" comment.
- [ ] Non-parent issue with `Closes/Fixes/Resolves #NNN` PR merge still
  receives full closing hygiene (comment + atomic label edit). Baseline
  behaviour preserved.
- [ ] Label mutation is a single `gh issue edit` call — measurable by the
  timestamp of the resulting `labeled`/`unlabeled` events (<1s apart).
- [ ] `test-label-invariants.sh` (or equivalent new test) green.
- [ ] No new shellcheck findings on the workflow `run:` blocks.

## Context

- **Parent-task convention:** `prompts/build.txt` "Parent-task PR keyword
  rule (t2046)" and `templates/brief-template.md` "PR Conventions".
- **t2040 atomicity fix:** `.agents/scripts/issue-sync-helper.sh:360-378`
  (commented explicitly — useful reference for the why).
- **Existing closing-hygiene skip pattern (prior art):** PR #17986.
- **Observation session:** merge of PR #19238 then PR #19228 on 2026-04-16.
  Event timeline on #19222: `status:done` added at `03:12:20Z`,
  `status:in-review` removed at `03:12:25Z` (5s gap → 8 sequential
  `gh issue edit` calls).

## Tier checklist

- [x] Single-file surgical change in one workflow + one test → would fit
  `tier:simple` except brief needs narrative trade-off reasoning
- [ ] Default `tier:standard` because bug-fix touching CI behaviour requires
  context-aware verification (won't ship if downstream workflows break)
- [x] Estimate ~45min (diff ~30 lines + test) — dispatchable as standard

## CI/CD consequence audit

The user explicitly flagged "ensuring no unintended undesirable consequences
for our CI/CD needs and aims". Changes audited against aims:

| Aim | Current | After fix | Risk |
|---|---|---|---|
| Mark issues done on merge | Works for leaf issues; over-applies to parent-tasks | Works for leaf issues; correctly skips parent-tasks | None |
| Post closing comment audit trail | Posts "Completed via…" on all linked | Still posts on leaf; skips on parent (incorrect "Completed via" message) | Audit trail on parent moves to the existing "Parent-task phase nudge" step (line 460+) which is more accurate |
| Remove stale status labels | 7 separate API calls, 5s window | Single atomic call | Downstream `issues.labeled` triggers still fire — event semantics unchanged |
| Support rejection labels (not-planned/wontfix) | Skip hygiene path at line 400 | Unchanged | None — my skip is additive |
| Support `Closes/Fixes/Resolves` → parent-task (terminal phase) | Hygiene runs (correct) | Hygiene runs (correct) | None — skip only applies to title-fallback |
| Concurrency across multiple PRs merging | `concurrency: group: issue-sync-pr-<PR>` serialises | Unchanged | None |

**Net:** strictly corrective. No new failure modes introduced, one false-positive
class eliminated, one atomicity race closed.
