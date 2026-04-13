<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2032: Tighten pulse deterministic merge-pass close-comment wording (GH#17574)

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) via interactive session
- **Parent task:** none
- **Conversation context:** While verifying the closing reasons on PR #18486, the user noticed the `_close_conflicting_pr` template in `pulse-merge.sh` says "committed directly to main" when the task may have landed via a *merged PR*, not a direct commit. PR #18486's sibling (#18480) was merged via PR flow 1m46s before #18486 was auto-closed — the wording misrepresents the audit trail.

## What

Fix the "work is already on main" close-comment template in `.agents/scripts/pulse-merge.sh::_close_conflicting_pr()` so it:

1. Never says "committed **directly** to main" — the word "directly" is factually wrong whenever the task landed via a merged PR (the common case).
2. Cites the **actual merging PR number** when detectable, so the audit trail is one click away. Example: "The work for this task (`t2017`) has already landed on main (via PR #18480), so no re-attempt is needed."
3. Falls back cleanly when the task_id match is on a non-squash commit (no `(#NNN)` suffix) or we can't parse a PR number — emit "has already landed on main" without the parenthetical.
4. Updates the companion `pulse-dispatch-core.sh` comment (line 605) and the test file header comment for consistency — both currently say "committed directly to main".

## Why

The comment is the only audit trail attached to the closed PR. When it misrepresents *how* the work reached main, anyone reading the thread later has to re-derive the truth (as we just did for #18486). Citing the merging PR number turns a misleading one-liner into a self-documenting link. Cost of fix ~15 min; saved debugging time over the lifetime of the framework is much larger.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 3 files (pulse-merge.sh, pulse-dispatch-core.sh comment, test file comment), but only one has logic changes
- [x] **Complete code blocks for every edit?** — yes, all exact
- [x] **No judgment or design decisions?** — yes, the wording is specified
- [x] **No error handling or fallback logic to design?** — yes, the fallback (no PR number parseable) is specified below
- [x] **Estimate 1h or less?** — yes, ~20 min
- [x] **4 or fewer acceptance criteria?** — 4

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file logic change with verbatim replacement blocks; two trivial comment-only edits in companion files. No design decisions. Fallback behaviour for missing PR number is fully specified.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge.sh:968-1001` — extract the merging PR number and rewrite the close-comment string
- `EDIT: .agents/scripts/pulse-dispatch-core.sh:605` — comment wording
- `EDIT: .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh:8` — test-file header comment
- `NEW: .agents/scripts/tests/test-close-conflicting-pr-wording.sh` — regression test asserting the new wording

### Implementation Steps

1. **`.agents/scripts/pulse-merge.sh` — `_close_conflicting_pr` rewrite**: after the existing commit-match check returns `work_on_main="true"`, query the GitHub commits API for the matching commit's subject line. Squash-merge commits have the form `…(#NNN)` — parse with a grep. If found, include the PR number in the message; otherwise omit it.

    Replace the block (lines 971–992) with:

    ```bash
    # GH#17574 / t2032: Check if the work is already on the default branch.
    # Extract task ID from PR title (e.g., "t153: add dark mode" → "t153")
    # and search recent commits on the default branch. When found, try to
    # extract the merging PR number from the squash-merge suffix "(#NNN)"
    # so the close comment can cite the actual audit trail.
    local work_on_main="false"
    local merging_pr=""
    local task_id_from_pr
    task_id_from_pr=$(printf '%s' "$pr_title" | grep -oE '^(t[0-9]+|GH#[0-9]+)' | head -1) || task_id_from_pr=""

    if [[ -n "$task_id_from_pr" ]]; then
        # Fetch recent commit subjects and find the first one matching the task ID.
        local commit_subjects
        commit_subjects=$(gh api "repos/${repo_slug}/commits" \
            --method GET -f sha=main -f per_page=50 \
            --jq ".[] | .commit.message | split(\"\n\")[0]" \
            2>/dev/null) || commit_subjects=""

        local matching_subject
        matching_subject=$(printf '%s\n' "$commit_subjects" \
            | grep -iE "(^|[^a-z0-9])${task_id_from_pr}([^a-z0-9]|$)" \
            | head -1) || matching_subject=""

        if [[ -n "$matching_subject" ]]; then
            work_on_main="true"
            # Parse "(#NNN)" suffix from squash-merge commit subject.
            merging_pr=$(printf '%s' "$matching_subject" \
                | grep -oE '\(#[0-9]+\)$' \
                | grep -oE '[0-9]+') || merging_pr=""
        fi
    fi

    if [[ "$work_on_main" == "true" ]]; then
        local landed_via=""
        if [[ -n "$merging_pr" ]]; then
            landed_via=" (via PR #${merging_pr})"
        fi
        # Work is already on main — close PR with accurate message
        gh pr close "$pr_number" --repo "$repo_slug" \
            --comment "Closing — this PR has merge conflicts with the base branch. The work for this task (\`${task_id_from_pr}\`) has already landed on main${landed_via}, so no re-attempt is needed.

_Closed by deterministic merge pass (pulse-wrapper.sh, GH#17574)._" 2>/dev/null || true
    ```

2. **`.agents/scripts/pulse-dispatch-core.sh:605`** — change comment:

    ```bash
    # GH#17574: Check if a task has already landed on main (via PR merge or direct commit).
    ```

3. **`.agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh:8`** — change comment:

    ```bash
    # when a task has already landed on main (via PR merge or direct commit),
    ```

4. **New test `.agents/scripts/tests/test-close-conflicting-pr-wording.sh`**: exercises the wording logic by sourcing the extracted function with a stubbed `gh` that returns a known squash-merge commit subject, then asserts the generated comment contains `landed on main (via PR #N)` and does NOT contain `committed directly to main`.

### Verification

```bash
cd ~/Git/aidevops-feature-gh17574-close-comment-wording
shellcheck .agents/scripts/pulse-merge.sh .agents/scripts/pulse-dispatch-core.sh
bash .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh
bash .agents/scripts/tests/test-close-conflicting-pr-wording.sh
rg -n 'committed directly to main' .agents/scripts/ && echo "FAIL: stale wording remains" || echo "OK: no stale wording"
```

## Acceptance Criteria

- [ ] `pulse-merge.sh::_close_conflicting_pr` no longer emits "committed directly to main"; emits "has already landed on main" instead.
  ```yaml
  verify:
    method: codebase
    pattern: "committed directly to main"
    path: ".agents/scripts/pulse-merge.sh"
    expect: absent
  ```
- [ ] When the matching commit's subject has a `(#NNN)` suffix, the close comment includes `(via PR #NNN)`.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-close-conflicting-pr-wording.sh"
  ```
- [ ] Existing pulse-wrapper main-commit-check tests still pass.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh"
  ```
- [ ] Shellcheck clean on both modified scripts.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-merge.sh .agents/scripts/pulse-dispatch-core.sh"
  ```

## Context & Decisions

- **Why parse `(#NNN)` from the subject instead of `gh api .../commits/{sha}/pulls`?** The pulls API endpoint works but costs an extra request per check, runs during every dispatch pass, and is only informational. Squash-merge is the default merge strategy in this repo (`full-loop-helper.sh merge` uses `--squash`), so ~100% of recent merges have the suffix. Fallback to "landed on main" without the parenthetical is acceptable for the rare non-squash case.
- **Why not also update the issue-body close comment?** GH#17642 explicitly left the linked *issue* open in this path — only the PR comment is edited. No issue comment changes needed.
- **Non-goal:** we are NOT changing the detection logic (which commits count as "work on main"). That was settled in GH#17574 and t2004. Only the user-facing wording changes.
- **Prior art:** PR #18480 vs closed PR #18486 is the concrete case that exposed this — a side-by-side parallel PR where the sibling landed via squash merge, not a direct commit.

## Relevant Files

- `.agents/scripts/pulse-merge.sh:968-1001` — the function being edited
- `.agents/scripts/pulse-dispatch-core.sh:604-655` — companion detection helper; comment fix only
- `.agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh` — existing regression coverage; header comment fix + keep green

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | already done in this session |
| Implementation | 10m | three file edits + one new test |
| Testing | 5m | run shellcheck + two bash tests |
| **Total** | **~20m** | |
