<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2219: issue-sync.yml title-fallback applies status:done to non-parent issues referenced via 'For #NNN'

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code interactive session
- **Created by:** ai-interactive (Marcus Quinn driving)
- **Conversation context:** PR #19701 was a planning-only PR that shipped briefs for three future tasks (t2206/t2207/t2208) referencing issues via `For #19692`, `For #19693`, `For #19694` per the t2046 planning convention. After merge, issue #19692 received `status:done` even though no Closes/Fixes/Resolves keyword was used. Investigation traced the false-positive to `.github/workflows/issue-sync.yml` `sync-on-pr-merge` job's title-fallback search at line 412-414 which finds an issue by extracting the leading task ID from the PR title and matching it against open issues — picking up #19692 because both shared the `t2206:` prefix. The existing t2137 carve-out only protects `parent-task` issues; normal `tier:standard`/`tier:simple` issues referenced via `For` are vulnerable.

## What

Extend the `issue-sync.yml::sync-on-pr-merge::find-issue` step's title-fallback logic so that issues referenced via `For #NNN` or `Ref #NNN` in the PR body are excluded from the title-fallback match — not just `parent-task`-labeled issues. The semantic is: "For/Ref means do not auto-close, do not auto-status-done; only `Closes/Fixes/Resolves` triggers those side effects." After the fix, planning PRs that title themselves with the first referenced future-task ID (the t2206 case) will not incorrectly mark referenced issues as done.

## Why

The current behavior corrupts the audit trail for planning PRs:
1. Maintainer files a planning PR titled `tNNN: plan ...` referencing future work via `For #NNN`.
2. Workflow finds the future-work issue by title-fallback and marks it `status:done`.
3. Pulse + dashboards now think the issue is closed, but it's still open with implementation pending.
4. Maintainer notices later and manually removes the label — a tax on every planning PR.

The t2046 planning convention (`For #NNN` = future work, no auto-close) is supposed to be the safe escape hatch for planning PRs. The title-fallback violates that contract for non-parent issues.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (1 workflow + 1 new test = 2 files)
- [ ] **Every target file under 500 lines?** (issue-sync.yml is 1189 lines)
- [ ] **Exact `oldString`/`newString` for every edit?** (skeleton provided, but the YAML insertion involves multi-line bash logic — implementer needs to refine)
- [x] **No judgment or design decisions?** (mirror t2137 pattern; one design choice — exclude-by-body-reference vs exclude-when-no-closer — is documented below)
- [x] **No error handling or fallback logic to design?** (existing logic already handles all paths)
- [x] **No cross-package or cross-module changes?** (single workflow + test)
- [x] **Estimate 1h or less?** (~1-2h with test)
- [x] **4 or fewer acceptance criteria?** (4)

**Selected tier:** `tier:standard`

**Tier rationale:** Workflow YAML logic change with a clear pattern to extend (t2137 already does parent-task exclusion at the same spot), but the file is large, the change involves multi-line bash inside a YAML run block, and a workflow-level integration test (acted-style or fixture-based) is needed. Sonnet handles this comfortably; Haiku would struggle with the YAML/bash interleaving without verbatim oldString/newString.

## PR Conventions

Leaf (non-parent) issue. PR body MUST use `Resolves #19719`.

## Files to Modify

- `EDIT: .github/workflows/issue-sync.yml` — extend `sync-on-pr-merge::find-issue` step (lines 395-431) to exclude issues referenced via `For #NNN` / `Ref #NNN` from title-fallback
- `NEW: .agents/scripts/tests/test-issue-sync-for-ref-skip.sh` — fixture-based test asserting that a PR body with only `For #NNN` references does not produce a `found_issues` value matching that NNN

## Implementation Steps

### Step 1: Extract `For/Ref` references during the `extract` step

In the existing `extract` step (around line 360-390 of `issue-sync.yml`), in addition to extracting `LINKED_ISSUES` (Closes/Fixes/Resolves), extract `FOR_REF_ISSUES`:

```bash
# Collect 'For #NNN' and 'Ref #NNN' references (planning convention t2046)
# These are explicit signals that the PR is NOT closing the referenced issue.
FOR_REF_ISSUES=""
if [[ -n "$PR_BODY" ]]; then
  FOR_REF_ISSUES=$(echo "$PR_BODY" | grep -oiE '(for|ref)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true)
fi
echo "for_ref_issues=$FOR_REF_ISSUES" >> "$GITHUB_OUTPUT"
```

Add immediately after the existing `LINKED_ISSUES` extraction (line 380-384).

### Step 2: Wire `for_ref_issues` into the `find-issue` step

Add `FOR_REF_ISSUES: ${{ steps.extract.outputs.for_ref_issues }}` to the env block of the `find-issue` step (lines 398-402).

### Step 3: Skip title-fallback for `For/Ref`-referenced issues

In the title-fallback block (lines 411-427), after the existing parent-task probe, add a check: if `FOUND` is in `FOR_REF_ISSUES`, skip the fallback. Insert between the existing parent-task check (line 417) and the accept-branch (line 421):

```bash
# t2219: skip title-fallback when the issue was explicitly referenced
# via 'For #NNN' or 'Ref #NNN' in the PR body. The t2046 planning
# convention says these references mean "this PR does NOT close that
# issue" — extend the same semantics to status:done auto-application.
elif [[ " $FOR_REF_ISSUES " == *" $FOUND "* ]]; then
  echo "found_issues=" >> "$GITHUB_OUTPUT"
  echo "Found issue #$FOUND for task $TASK_ID is referenced via For/Ref in PR body — skipping title-fallback hygiene (t2219)"
```

The block becomes (insertion in context):

```bash
if echo "$FOUND_LABELS" | grep -qw "parent-task"; then
  echo "found_issues=" >> "$GITHUB_OUTPUT"
  echo "Found issue #$FOUND for task $TASK_ID is a parent-task — skipping title-fallback hygiene (use explicit Closes #NNN on the terminal-phase PR to close a parent)"
elif [[ " $FOR_REF_ISSUES " == *" $FOUND "* ]]; then
  echo "found_issues=" >> "$GITHUB_OUTPUT"
  echo "Found issue #$FOUND for task $TASK_ID is referenced via For/Ref in PR body — skipping title-fallback hygiene (t2219)"
else
  echo "found_issues=$FOUND" >> "$GITHUB_OUTPUT"
  echo "Found issue #$FOUND for task $TASK_ID"
fi
```

### Step 4: Add a regression test

Create `.agents/scripts/tests/test-issue-sync-for-ref-skip.sh`. The test should be a fixture-style bash script that simulates the workflow's logic in isolation:

```bash
#!/usr/bin/env bash
# Regression test for t2219: PR body with For/Ref references must not
# trigger the issue-sync.yml title-fallback against the referenced issues.
set -euo pipefail

# Simulate the extract step's regex against a known PR body
PR_BODY='## Summary

Plans three follow-up tasks.

For #19692
For #19693
For #19694
'

LINKED=$(echo "$PR_BODY" | grep -oiE '(closes?|fixes?|resolves?)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true)
FOR_REF=$(echo "$PR_BODY" | grep -oiE '(for|ref)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true)

# Assertions
if [[ -n "${LINKED// /}" ]]; then
  echo "FAIL: LINKED_ISSUES should be empty, got: '$LINKED'"
  exit 1
fi
expected="19692 19693 19694 "
if [[ "$FOR_REF" != "$expected" ]]; then
  echo "FAIL: FOR_REF_ISSUES expected '$expected', got '$FOR_REF'"
  exit 1
fi

# Simulate the find-issue title-fallback skip check
FOUND=19692
if [[ " $FOR_REF " == *" $FOUND "* ]]; then
  echo "PASS: title-fallback would skip #$FOUND because it is in For/Ref"
  exit 0
else
  echo "FAIL: title-fallback would NOT skip #$FOUND despite For/Ref"
  exit 1
fi
```

Make executable, add to test runner discovery (typically anything matching `test-*.sh` in `.agents/scripts/tests/` is picked up — verify).

## Verification

```bash
# 1. yamllint clean (if configured)
yamllint .github/workflows/issue-sync.yml || true  # may not be enforced

# 2. shellcheck the new test
shellcheck .agents/scripts/tests/test-issue-sync-for-ref-skip.sh

# 3. Run the new test
bash .agents/scripts/tests/test-issue-sync-for-ref-skip.sh

# 4. Manual repro after merge: file a planning PR with title 'tNNN: ...' and body
#    containing only 'For #X' (where X is an issue titled 'tNNN: ...'). Merge.
#    Verify #X did NOT receive status:done.
```

## Acceptance Criteria

- [ ] `extract` step produces a `for_ref_issues` output containing space-separated issue numbers from `For #NNN` / `Ref #NNN` references in PR body
- [ ] `find-issue` step's title-fallback skips issues whose number appears in `for_ref_issues`
- [ ] Regression test `test-issue-sync-for-ref-skip.sh` exists and passes
- [ ] Existing t2137 parent-task carve-out still works (no regression on parent-task issues)

## Context & Decisions

- **Design choice — exclude-by-body-reference vs exclude-when-no-closer.** Two valid approaches:
  1. (chosen) Skip title-fallback for issues explicitly referenced via `For/Ref`. Surgical: only suppresses the false-positive case.
  2. Skip title-fallback entirely when PR body has any `For/Ref` and no `Closes/Fixes/Resolves`. More conservative: protects against a class of false positives but might miss legitimate auto-closes for issues that share a task ID prefix without being referenced.

  Approach 1 is preferred because it preserves the existing positive cases (PR with `Closes #X` and title `tX: ...` should still apply hygiene to #X via either path) while specifically targeting the documented false-positive pattern.

- **Why not change PR title convention instead?** The framework rule is "PR title MUST have task ID `tNNN: description`" (see `prompts/build.txt` "Traceability"). Loosening this for planning PRs would weaken cross-PR audit linkage. The fix belongs in the workflow, not the convention.

- **Cross-cutting consideration with t2191 and t2206/t2207/t2208.** This bug exists today and was masked because the maintainer manually fixed the false `status:done` on #19692. Once t2206/t2207 land via worker dispatch, those workers may also file planning sub-PRs. Having this fix in place avoids the same manual cleanup tax for them.

- **Why a fixture-based test instead of an `act` integration test?** `act` requires a Docker environment and is heavyweight for a regex+conditional change. A bash fixture that simulates the relevant snippets is sufficient to catch regressions without CI complexity. If the team standardises on `act` later, this test can be promoted.

## Relevant files

- **Edit:** `.github/workflows/issue-sync.yml` — `extract` step (lines 360-390) + `find-issue` step (lines 395-431)
- **New:** `.agents/scripts/tests/test-issue-sync-for-ref-skip.sh`
- **Pattern source:** existing t2137 parent-task carve-out at lines 415-419
- **Convention:** `.agents/templates/brief-template.md` "PR Conventions" section + `prompts/build.txt` "Traceability" / "Parent-task PR keyword rule (t2046)"

## Dependencies

None. Self-contained workflow + test fix. Independent of t2218.
