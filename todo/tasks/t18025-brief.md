<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18025: fix(pulse-merge-conflict): use PR base branch in conflict nudges

## Pre-flight

- [x] Memory recall: `review issue pr 25780 dispatch-ready TODO worker brief baseRefName hardcoded main` → 0 hits — no relevant prior lesson found.
- [x] Discovery pass: 0 commits / 1 unrelated merged PR / 0 open PRs touched or matched the target since issue creation; no superseding fix found.
- [x] File refs verified: `.agents/scripts/pulse-merge-conflict.sh`, `.agents/scripts/tests/test-close-conflicting-pr-wording.sh`, and `.agents/scripts/tests/test-pulse-merge-rebase-nudge.sh` present at HEAD; cited hardcoded branch strings verified at current line ranges below.
- [x] Tier: `tier:standard` — target script is 1,248 lines and test coverage spans two existing shell test files, so this is not `tier:simple` under the brief template despite low conceptual complexity.
- [x] Seeded draft PR decision recorded: skipped — the implementation is straightforward but should be done as the final worker PR with tests, not as an unverified seed.

## Origin

- **Created:** 2026-06-28
- **Session:** opencode:unknown-2026-06-28
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** None
- **Blocked by:** None
- **Conversation context:** GH#25780 was reviewed and approved. The review found that conflict-nudge comments in `pulse-merge-conflict.sh` hardcode `main` instead of the PR base branch, producing wrong rebase instructions for repositories whose base branch is `develop` or another non-`main` branch.

## What

Update the pulse merge-conflict messaging so every rebase nudge and duplicate-close comment names the PR's actual base branch. A PR targeting `develop` must receive comments and commands that reference `develop`, not `main`.

## Why

Managed repositories can target non-`main` branches. Current comments can instruct maintainers, contributors, and workers to rebase against the wrong branch, which can worsen conflicts and waste reviewer/worker time. The bug is accepted in GH#25780 and has been reproduced statically against current source.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Primary script plus two focused test files is three files, so this fails `tier:simple`.
- [ ] **Every target file under 500 lines?** `.agents/scripts/pulse-merge-conflict.sh` is 1,248 lines and `.agents/scripts/tests/test-close-conflicting-pr-wording.sh` is 765 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** Guidance includes skeletons and assertions, not every exact replacement.
- [x] **No judgment or design decisions?** The accepted direction is fixed: use `baseRefName` with a safe fallback.
- [ ] **No error handling or fallback logic to design?** The worker must preserve fail-open fallback behaviour.
- [x] **No cross-package or cross-module changes?** All files are in `.agents/scripts/` and its tests.
- [x] **Estimate 1h or less?** Expected implementation is about 45-60 minutes.
- [x] **4 or fewer acceptance criteria?** Four criteria are listed below.
- [x] **Dispatch-path classification (t2821/t2920):** Target files are not listed in `.agents/configs/self-hosting-files.conf`.

**Selected tier:** `tier:standard`

**Tier rationale:** The fix is conceptually small, but the primary script and one test file are over 500 lines and the worker needs to preserve fail-open branch-metadata fallback behaviour. Use `tier:standard` to avoid a false `tier:simple` dispatch.

## PR Conventions

Leaf task: implementation PR should use `Resolves #25780`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The brief contains verified file paths, current line ranges, and implementation skeletons. A draft PR would add little value and could be mistaken for a complete fix before tests run.
- **Status:** not-created
- **Freshness evidence:** Memory recall, duplicate/in-flight discovery, and file-line verification were performed on 2026-06-28 against `65f344207`.
- **Verification run:** UNVERIFIED — no code changes made in this planning task.
- **Stale-assumption warning:** Re-check `pulse-merge-conflict.sh` if any PR touching conflict nudges lands before implementation.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-merge-conflict.sh`
  - Current hardcoded lines verified: interactive nudge `.agents/scripts/pulse-merge-conflict.sh:90-108`, contributor nudge `:154-172`, worker nudge `:539-564`, close comment `:998-1005`.
- EDIT: `.agents/scripts/tests/test-pulse-merge-rebase-nudge.sh`
  - Current stub only handles `headRefName` at `.agents/scripts/tests/test-pulse-merge-rebase-nudge.sh:54-63` and tests only interactive nudge body at `:109-132`.
- EDIT: `.agents/scripts/tests/test-close-conflicting-pr-wording.sh`
  - Current stub documents only `headRefName` at `.agents/scripts/tests/test-close-conflicting-pr-wording.sh:57-63`, handles it at `:145-149`, and currently asserts `landed on main` wording at `:288`, `:320`, and `:431`.

### Complexity Impact

- Existing functions that may grow:
  - `_post_rebase_nudge_on_interactive_conflicting()` currently spans `.agents/scripts/pulse-merge-conflict.sh:75-123` (49 lines).
  - `_post_rebase_nudge_on_contributor_conflicting()` currently spans `.agents/scripts/pulse-merge-conflict.sh:143-186` (44 lines).
  - `_post_rebase_nudge_on_worker_conflicting()` currently spans `.agents/scripts/pulse-merge-conflict.sh:526-579` (54 lines).
  - `_close_conflicting_pr_after_verified_match()` starts at `.agents/scripts/pulse-merge-conflict.sh:989` and contains the close comment at `:1002-1005`.
- Recommended shape: add one small helper for PR branch refs instead of growing each nudge function. Keep each touched function below 80 lines.
- Expected added lines: ~25-45 lines in the script plus test assertions.

### Implementation Steps

1. Add a small branch-ref helper near the rebase nudge helpers in `.agents/scripts/pulse-merge-conflict.sh`.

   ```bash
   _get_pr_branch_refs_for_conflict_comment() {
     local pr_number="$1"
     local repo_slug="$2"
     local branch_refs=""
     local head_branch=""
     local base_branch=""

     branch_refs=$(gh pr view "$pr_number" --repo "$repo_slug" \
       --json headRefName,baseRefName \
       --jq '[.headRefName // "<branch>", .baseRefName // "main"] | @tsv' 2>/dev/null) || branch_refs=""
     if [[ -n "$branch_refs" ]]; then
       IFS=$'\t' read -r head_branch base_branch <<<"$branch_refs"
     fi
     [[ -n "$head_branch" ]] || head_branch="<branch>"
     [[ -n "$base_branch" ]] || base_branch="main"

     printf '%s\t%s\n' "$head_branch" "$base_branch"
     return 0
   }
   ```

2. In each of the three nudge functions, replace the `gh pr view --json headRefName` block with helper parsing, then use `${base_branch}` in the heading, descriptive sentence, and command.

   ```bash
   local branch_refs
   local head_branch
   local base_branch
   branch_refs=$(_get_pr_branch_refs_for_conflict_comment "$pr_number" "$repo_slug") || branch_refs=$'<branch>\tmain'
   IFS=$'\t' read -r head_branch base_branch <<<"$branch_refs"
   [[ -n "$head_branch" ]] || head_branch="<branch>"
   [[ -n "$base_branch" ]] || base_branch="main"
   ```

   Expected user-facing replacements:
   - `branch has diverged from \`main\`` → `branch has diverged from \`${base_branch}\``
   - `merge conflicts against \`main\`` → `merge conflicts against \`${base_branch}\``
   - `git pull --rebase origin main` → `git pull --rebase origin ${base_branch}`
   - `git rebase origin/main` → `git rebase origin/${base_branch}`

3. Update `_close_conflicting_pr_after_verified_match()` so the close comment says the work landed on the actual base branch. It can call the same helper and ignore the head branch.

   ```bash
   local branch_refs
   local _head_branch
   local base_branch
   branch_refs=$(_get_pr_branch_refs_for_conflict_comment "$pr_number" "$repo_slug") || branch_refs=$'<branch>\tmain'
   IFS=$'\t' read -r _head_branch base_branch <<<"$branch_refs"
   [[ -n "$base_branch" ]] || base_branch="main"
   ```

   Then change `has already landed on main${landed_via}` to `has already landed on ${base_branch}${landed_via}`.

4. Update tests:
   - In `test-pulse-merge-rebase-nudge.sh`, make the `gh` stub return both refs for `--json headRefName,baseRefName`, e.g. `fix/example-branch<TAB>develop`. Assert the nudge contains `develop`, `git pull --rebase origin develop`, and does not contain `origin main` or `origin/main`.
   - Extend the test to cover contributor and worker nudge helpers, or add focused assertions in an existing conflict wording test if extraction is easier.
   - In `test-close-conflicting-pr-wording.sh`, update the stub to handle `baseRefName` or combined `headRefName,baseRefName`; set the base branch fixture to `develop`; update affected assertions from `landed on main` to `landed on develop` while preserving direct-to-main historical test descriptions where they refer to commit search semantics.

### Verification

Run from repo root:

```bash
shellcheck .agents/scripts/pulse-merge-conflict.sh \
  .agents/scripts/tests/test-pulse-merge-rebase-nudge.sh \
  .agents/scripts/tests/test-close-conflicting-pr-wording.sh
.agents/scripts/tests/test-pulse-merge-rebase-nudge.sh
.agents/scripts/tests/test-close-conflicting-pr-wording.sh
```

If broader changes are made, also run:

```bash
.agents/scripts/linters-local.sh
```

## Acceptance

- For a PR fixture with `baseRefName=develop`, every rebase nudge says conflicts are against `develop` and uses `origin develop` / `origin/develop` commands as appropriate.
- The duplicate-close comment says the task landed on the PR base branch, not always on `main`.
- Existing fallback behaviour remains fail-open: if the `gh pr view` branch lookup fails, comments still render with safe defaults and the merge pass does not fail.
- ShellCheck and the two targeted shell tests pass.

## Context

- Source issue: GH#25780.
- Review comment: https://github.com/marcusquinn/aidevops/issues/25780#issuecomment-4826042733
- `baseRefName` is already used elsewhere in pulse merge processing; this task aligns conflict messaging with that pattern instead of adding a new branch source.
- Existing comments already posted on old PRs do not need retroactive correction.
