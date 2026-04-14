---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2084: fix(issue-sync): unconditionally unlock linked issues before posting closing comment + drift detection

## Origin

- **Created:** 2026-04-14
- **Session:** Claude:bugfix-t2084-issue-sync-unlock
- **Created by:** ai-interactive (user-directed)
- **Conversation context:** User reported `awardsapp/awardsapp#2273` was closed by PR `#2333` without the usual "Completed via PR #N" closing comment. They asked for root cause + systemic fix + how to ensure it doesn't recur.

## What

Three-layer defensive fix to guarantee that every PR merge posts a closing comment on its linked issue, regardless of who/what merged it:

1. **Workflow hardening** (`.github/workflows/issue-sync.yml`): unconditionally unlock the linked issue *before* attempting to post the closing comment, so manual GitHub-UI merges, third-party-bot merges, and any other non-pulse merge path always succeed in commenting. The current `IS_LOCKED` check (added in `fd48d8c9b`, GH#17794) gracefully *skips* the comment on locked issues — that is a tourniquet, not a fix. A locked issue post-merge is the bug; unlocking it is the right action.
2. **Workflow drift detection routine** (`r-NNN`): a daily/weekly routine that walks every `pulse: true` repo in `~/.config/aidevops/repos.json`, fetches its `.github/workflows/issue-sync.yml`, compares the SHA against the upstream `.agents/...` source, and files a tracking issue (or auto-PRs the refresh) when they diverge. Without this, a fix in the upstream framework never reaches `awardsapp` until somebody manually re-syncs it.
3. **Backfill helper** (`backfill-orphaned-closing-comments.sh`): one-shot script that scans the last N closed issues in a target repo, finds those that are locked AND have no "Completed via PR #" comment from their closing PR, unlocks them, and posts the missing comment. Use this to clean up the 27 affected `awardsapp` issues identified during root-cause analysis.

## Why

**The bug observed:** `awardsapp/awardsapp#2273` (`t222: Build MCP server adapter`) was closed by PR `#2333` (merged manually by `@alex-solovyev` at `2026-04-14T02:02:16Z`). No closing comment landed on either the issue or the PR. Investigation revealed the GitHub Actions `sync-on-pr-merge` workflow [crashed at 02:02:28Z](https://github.com/awardsapp/awardsapp/actions/runs/24376942551) with:

```
GraphQL: Unable to create comment because issue is locked (addComment)
##[error]Process completed with exit code 1.
```

**Cascading root cause** (each layer is a separate weakness; fix any one and this specific failure goes away, but only fixing all three prevents recurrence in adjacent failure modes):

| # | Layer | Why it failed |
|---|-------|---------------|
| 1 | The `gh issue comment` call in `sync-on-pr-merge` | Issue was locked. GraphQL `addComment` rejects locked issues with HTTP 200 + GraphQL error → `gh` exits 1 → `set -e` kills the step. |
| 2 | The issue was locked at dispatch time | `lock_issue_for_worker` (t1934, in `pulse-dispatch-core.sh`) locks issues on dispatch to prevent contributor edits during worker execution. The symmetric `unlock_issue_after_worker` is called from `pulse-merge.sh:_handle_post_merge_actions`, `pulse-cleanup.sh`, `pulse-issue-reconcile.sh`, and `worker-watchdog.sh`. None of those fire on a successful **manual** merge — only the pulse's deterministic merge pass calls them. |
| 3 | The deployed workflow doesn't have the locked-issue check at all | `awardsapp/awardsapp/.github/workflows/issue-sync.yml` is several commits behind the upstream framework. It predates `fd48d8c9b` (`GH#17794: fix: skip closing comment on locked issues in Sync Issue Hygiene workflow`) which added the `IS_LOCKED` early-skip. Verified by `gh api repos/awardsapp/awardsapp/contents/.github/workflows/issue-sync.yml \| jq -r .content \| base64 -d \| grep IS_LOCKED` returning zero matches. The deployed copy still says `merged to develop` (the old text); the upstream says `merged to main`. |
| 4 | There's no propagation system for framework workflow updates | Consumer repos snapshot `.github/workflows/*.yml` at `aidevops init` time and drift forever. No routine, no PR, no warning. The fix exists upstream but it's invisible to consumers. |

**Scope of the bug:** A `gh api graphql` scan of the last 100 closed `awardsapp/awardsapp` issues found **27 closed-but-still-locked issues**. Every one is a pre-existing lock leak from the same root cause. The number will keep growing every time a human clicks "Merge" instead of letting the pulse do it.

**Why "this used to work":** Before t1934 (dispatch-time issue locking), issues were never locked, so the `gh issue comment` call always succeeded regardless of merge path. The combination of (a) t1934 locking + (b) manual merges + (c) stale deployed workflow without the locked-check is what broke it.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — No: 1 workflow file + 1 new routine script + 1 new backfill script + 1 routine doc = 4 files.
- [x] **Complete code blocks for every edit?** — Yes for the workflow edit (exact diff below); skeletons for the new scripts (model on existing patterns).
- [x] **No judgment or design decisions?** — Mostly no, but the drift-detection routine has a "auto-PR vs file-issue" choice point.
- [x] **No error handling or fallback logic to design?** — Some: the backfill needs to handle PRs that closed multiple issues, repos without recent PRs, locked-AND-pinned issues, etc.
- [x] **Estimate 1h or less?** — No, 3-4h total.
- [x] **4 or fewer acceptance criteria?** — No, 7 criteria.

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file with new scripts, design choices around the drift-detection routine (auto-PR vs file-issue, refresh frequency), and 7 acceptance criteria put this firmly in standard tier. Not reasoning — every part has clear existing patterns to model on.

## PR Conventions

Leaf issue, not a parent task. PR body uses `Resolves #18814`.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Confirm the upstream workflow has the IS_LOCKED check (the "skip" tourniquet)
#    but NOT the unlock-before-comment fix:
grep -n "IS_LOCKED\|gh issue unlock" .github/workflows/issue-sync.yml
# Expect: 1 match for IS_LOCKED (line 423), 0 matches for "gh issue unlock"

# 2. The exact insertion point for the unlock call is BEFORE the locked-check,
#    inside the per-issue `for ISSUE_NUM in $ALL_ISSUES; do` loop, after the
#    rejection-label classification (so we don't unlock issues we won't comment on).

# 3. Pattern to follow for the drift detection routine:
#    pulse-routines.sh already iterates pulse-enabled repos; model on
#    .agents/scripts/contribution-watch-helper.sh which walks repos.json
#    and uses gh api per-repo.

# 4. Pattern for backfill helper: model on .agents/scripts/backfill-closure-labels.sh
#    which already does cross-repo issue-state remediation.
```

### Files to Modify

- `EDIT: .github/workflows/issue-sync.yml:404-434` — add unconditional `gh issue unlock` call before the closing-comment block; collapse the now-redundant `IS_LOCKED` check (or leave it as belt-and-braces if the unlock call fails for any reason).
- `NEW: .agents/scripts/workflow-drift-helper.sh` — daily-routine helper that walks `pulse: true` repos and detects stale workflow files. Model on `.agents/scripts/contribution-watch-helper.sh` for the per-repo iteration pattern, and on `.agents/scripts/version-check-helper.sh` for the SHA-comparison pattern.
- `NEW: .agents/scripts/backfill-orphaned-closing-comments.sh` — one-shot scan + backfill. Model on `.agents/scripts/backfill-closure-labels.sh` for the cross-repo issue-walking pattern.
- `EDIT: TODO.md` — add `r-NNN` routine entry under `## Routines` for the drift-detection routine, weekly schedule (`weekly(mon@09:00)` is sensible — gives a weekly nudge to refresh stale workflows).

### Implementation Steps

1. **Workflow fix — add unconditional unlock call** (`.github/workflows/issue-sync.yml`, in the per-issue loop in `Apply closing hygiene to linked issues` step):

   ```yaml
   for ISSUE_NUM in $ALL_ISSUES; do
     echo "--- Issue #$ISSUE_NUM ---"

     # Fetch issue labels to detect rejection state
     ISSUE_LABELS=$(gh api "repos/${REPO}/issues/${ISSUE_NUM}" --jq '[.labels[].name] | join(" ")' 2>/dev/null || echo "")
     IS_REJECTED=false
     # ... existing rejection detection ...

     # t2084: Unconditionally unlock the issue. The pulse locks issues at
     # dispatch time (t1934 in pulse-dispatch-core.sh:lock_issue_for_worker)
     # to prevent contributor-edit races during worker execution. The
     # symmetric unlock only fires when the *pulse* merges the PR via
     # _handle_post_merge_actions in pulse-merge.sh — manual merges, third-
     # party-bot merges, and GitHub-UI merges all leak the lock. PR-merge
     # is the canonical "work is done, lock is no longer needed" event;
     # unlock unconditionally here so any merge path completes cleanly.
     # Idempotent: gh issue unlock on an already-unlocked issue is a no-op.
     gh issue unlock "$ISSUE_NUM" --repo "$REPO" 2>/dev/null || true

     # Post closing comment if none exists from this PR
     # ... existing comment loop ...
   done
   ```

   The existing `IS_LOCKED` check (line 422-425) becomes a belt-and-braces fallback for the rare case where unlock fails (e.g., insufficient permissions on a forked PR's `pull_request_target` token).

2. **Drift detection helper** (`.agents/scripts/workflow-drift-helper.sh`):

   ```bash
   #!/usr/bin/env bash
   # SPDX-License-Identifier: MIT
   # workflow-drift-helper.sh — Detect stale .github/workflows/*.yml in
   # pulse-enabled consumer repos. Compares deployed file SHA against the
   # upstream framework source.

   set -euo pipefail
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   source "${SCRIPT_DIR}/shared-constants.sh"

   # The framework workflows that consumer repos receive at init time.
   # Model on .agents/scripts/contribution-watch-helper.sh:walk_repos for
   # the repos.json iteration pattern.
   readonly TRACKED_WORKFLOWS=(
     ".github/workflows/issue-sync.yml"
     ".github/workflows/maintainer-gate.yml"
     ".github/workflows/parent-task-keyword-check.yml"
     ".github/workflows/review-bot-gate.yml"
     # ... full list discoverable via `git ls-files .github/workflows/` in aidevops repo
   )

   cmd_check() {
     # 1. Resolve aidevops upstream path via framework-routing-helper
     # 2. For each pulse:true repo in repos.json:
     #    a. For each TRACKED_WORKFLOWS file:
     #       - gh api repos/SLUG/contents/PATH --jq .sha
     #       - git -C UPSTREAM hash-object PATH
     #       - if sha != upstream_sha: emit drift report
     # 3. Either: file an issue per drifted repo (default), OR
     #    open a PR with the refreshed file (--auto-pr flag)
     :
   }

   cmd_help() { ... }
   main() { ... }
   main "$@"
   ```

3. **Backfill helper** (`.agents/scripts/backfill-orphaned-closing-comments.sh`):

   ```bash
   #!/usr/bin/env bash
   # SPDX-License-Identifier: MIT
   # backfill-orphaned-closing-comments.sh — One-shot scan + backfill of
   # closed issues that are locked AND missing their "Completed via PR #"
   # closing comment. Use after t2084 lands to clean up the historical
   # backlog.

   # Usage:
   #   backfill-orphaned-closing-comments.sh scan <repo_slug>     [--limit N]
   #   backfill-orphaned-closing-comments.sh fix  <repo_slug>     [--limit N] [--dry-run]

   set -euo pipefail

   cmd_scan() {
     # gh api graphql query: last N closed issues, where locked == true
     # For each: find the closing PR via timeline (CLOSED_EVENT.closer.PullRequest)
     # Check if a "Completed via PR #N" comment already exists
     # Emit table: issue, pr, locked, has_comment
     :
   }

   cmd_fix() {
     # For each issue from cmd_scan with locked=true and has_comment=false:
     #   gh issue unlock $issue --repo $slug
     #   gh issue comment $issue --repo $slug --body "Completed via [PR #$pr](url). merged to main. (backfilled by t2084)"
     # Respect --dry-run
     :
   }
   ```

4. **Add routine to TODO.md** under `## Routines`:

   ```markdown
   - [x] r-NNN Workflow drift detection #routine repeat:weekly(mon@09:00) run:scripts/workflow-drift-helper.sh
   ```

5. **Run shellcheck** on new scripts: `shellcheck .agents/scripts/workflow-drift-helper.sh .agents/scripts/backfill-orphaned-closing-comments.sh`

6. **Validate the workflow YAML**: `yamllint .github/workflows/issue-sync.yml` (or `actionlint` if installed).

### Verification

```bash
# 1. Confirm the unlock call is in the workflow
grep -n "gh issue unlock" .github/workflows/issue-sync.yml
# Expect: 1 match inside the sync-on-pr-merge job's per-issue loop

# 2. Confirm new helpers exist and are executable
test -x .agents/scripts/workflow-drift-helper.sh && echo OK
test -x .agents/scripts/backfill-orphaned-closing-comments.sh && echo OK

# 3. Run drift detection in dry-run mode against the local repo set
.agents/scripts/workflow-drift-helper.sh check --dry-run

# 4. Run the backfill in scan-only mode against awardsapp
.agents/scripts/backfill-orphaned-closing-comments.sh scan awardsapp/awardsapp --limit 30
# Expect: ~27 issues flagged as locked + missing comment

# 5. Run the backfill for real (dry-run first)
.agents/scripts/backfill-orphaned-closing-comments.sh fix awardsapp/awardsapp --limit 30 --dry-run
.agents/scripts/backfill-orphaned-closing-comments.sh fix awardsapp/awardsapp --limit 30

# 6. Re-run the awardsapp graphql scan — locked count should drop to ~0
gh api graphql -f query='query { repository(owner:"awardsapp",name:"awardsapp") { issues(states:CLOSED,last:100) { nodes { locked } } } }' --jq '[.data.repository.issues.nodes[] | select(.locked == true)] | length'

# 7. shellcheck + actionlint pass
shellcheck .agents/scripts/workflow-drift-helper.sh .agents/scripts/backfill-orphaned-closing-comments.sh
```

## Acceptance Criteria

- [ ] `.github/workflows/issue-sync.yml` has an unconditional `gh issue unlock "$ISSUE_NUM" --repo "$REPO"` call inside the per-issue loop, BEFORE the closing-comment block, with an inline comment referencing t2084 + the t1934 lock-leak root cause.
  ```yaml
  verify:
    method: codebase
    pattern: 'gh issue unlock.*ISSUE_NUM.*REPO'
    path: .github/workflows/issue-sync.yml
  ```
- [ ] `.agents/scripts/workflow-drift-helper.sh` exists, is executable, and has commands `check` (default), `help`, and an `--auto-pr` flag for the auto-refresh path.
  ```yaml
  verify:
    method: bash
    run: "test -x .agents/scripts/workflow-drift-helper.sh && .agents/scripts/workflow-drift-helper.sh help | grep -q 'check'"
  ```
- [ ] `.agents/scripts/backfill-orphaned-closing-comments.sh` exists, is executable, and has commands `scan` and `fix` (with `--dry-run`).
  ```yaml
  verify:
    method: bash
    run: "test -x .agents/scripts/backfill-orphaned-closing-comments.sh && .agents/scripts/backfill-orphaned-closing-comments.sh help | grep -q 'scan'"
  ```
- [ ] `TODO.md` `## Routines` section contains a new `r-NNN` entry pointing at `workflow-drift-helper.sh` with a weekly schedule.
- [ ] Both new scripts pass `shellcheck` with zero violations.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/workflow-drift-helper.sh .agents/scripts/backfill-orphaned-closing-comments.sh"
  ```
- [ ] After running the backfill against `awardsapp/awardsapp --limit 100`, the count of locked-and-closed issues drops from 27 to 0 (or to whatever count is justified by issues legitimately locked for moderation reasons — none expected).
  ```yaml
  verify:
    method: manual
    prompt: "Run the backfill scan command and confirm the count drops to ~0."
  ```
- [ ] PR body uses `Resolves #18814` and the change ships to `main`. The next time anyone manually merges a PR with `Resolves #N`, the closing comment lands on the linked issue without operator intervention.

## Context & Decisions

- **Why unconditional unlock instead of "fix the lock leak in pulse-dispatch-core.sh"?** The lock is correct: it prevents contributor-edit races during worker execution. The leak is that *only the pulse's merge path* drops the lock. Adding unlock to every alternate merge path (manual UI, third-party bots, gh CLI, GitHub Actions auto-merge) is a never-ending whack-a-mole. Doing it once in the workflow that *fires on every merge regardless of who merged it* is the canonical fix.
- **Why not just remove the dispatch-time lock entirely?** The lock has a real purpose (t1894/t1934): it prevents prompt-injection attacks where a contributor edits the issue body mid-worker-run to inject instructions. The lock is correct; the unlock-on-completion plumbing is what's broken.
- **Why a separate drift-detection routine instead of pushing the workflow update directly to awardsapp now?** Both. The PR for this task does the awardsapp refresh; the routine prevents the same drift from recurring across all current and future pulse-enabled repos. Without the routine, the next time we ship a workflow fix, awardsapp will drift again — and the next consumer repo we onboard will start drifted.
- **Why a backfill helper instead of just the routine?** The routine prevents future drift but doesn't fix the 27 issues that already leaked. The backfill is a one-shot operation; once awardsapp is clean, the routine takes over.
- **Why post the closing comment on the PR too, not just the issue?** Auditability. The user explicitly asked for both. The PR comment thread is where reviewers, contributors, and future debuggers look for "what happened". Tying the issue and PR sides together makes the audit trail discoverable from either entry point.
- **Non-goals:** Rewriting the dispatch-time locking model. Migrating to GitHub Rulesets. Touching `pulse-merge.sh:_handle_post_merge_actions` (it already works correctly when the pulse merges — the bug is only the non-pulse path).

## Relevant Files

- `.github/workflows/issue-sync.yml:288-457` — the `sync-on-pr-merge` job and its `Apply closing hygiene to linked issues` step (where the unlock call goes).
- `.agents/scripts/pulse-dispatch-core.sh:514-528` — `unlock_issue_after_worker` (the function the deterministic merge pass calls; we mirror its semantics in the workflow).
- `.agents/scripts/pulse-merge.sh:733-790` — `_handle_post_merge_actions` (the working closing-comment path for pulse-driven merges, which we are replicating in the workflow for non-pulse merges).
- `.agents/scripts/contribution-watch-helper.sh` — model for the per-repo iteration pattern used by the new drift-detection helper.
- `.agents/scripts/backfill-closure-labels.sh` — model for the cross-repo issue-state remediation pattern used by the new backfill helper.
- `.agents/scripts/version-check-helper.sh` — model for the framework-vs-deployed SHA comparison used by the drift helper.
- `~/.config/aidevops/repos.json` — the input list for the drift-detection routine.

## Dependencies

- **Blocked by:** none
- **Blocks:** the next time a worker dispatches and gets killed mid-flight on `awardsapp` (the lock leaks again — backfill removes the historical leaks, the unlock-before-comment fix prevents new ones).
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | issue-sync.yml, contribution-watch-helper.sh, backfill-closure-labels.sh, repos.json structure |
| Implementation | 2.5h | workflow edit (~10m), drift helper (~1h), backfill helper (~1h), routine entry + brief refinement |
| Testing | 30m | shellcheck, dry-run scan/fix on awardsapp, validate workflow on a test PR |
| **Total** | **~3h** | tier:standard |
