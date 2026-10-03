<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worktree Cleanup After Merge

After a PR merges, clean up the linked worktree and return the canonical repo to a clean state.

**Key constraint:** Merge through `full-loop-helper.sh merge`; it records cleanup ownership and avoids deleting the branch while its worktree is active.

## Automated Cleanup (workers — GH#6740)

Workers dispatched via `/full-loop` defer current-worktree cleanup after successful immediate merges through `full-loop-helper.sh merge` (Step 4.9). The parent runtime may still use the worktree as a logical project `--dir` even when no OS process cwd points there. The pulse `cleanup_worktrees()` stage removes the deferred worktree after the owner exits. `--auto` only queues the merge, so scheduled cleanup also handles that later after the PR actually merges.

```bash
# Fallback/manual sequence after a lifecycle-helper merge succeeds:
WORKTREE_PATH="$(pwd)"
BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD)"
CANONICAL_DIR="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"

cd "$CANONICAL_DIR" || cd "$HOME"
git fetch origin main 2>/dev/null || true

HELPER="$HOME/.aidevops/agents/scripts/worktree-helper.sh"
if [[ -x "$HELPER" ]]; then
  WORKTREE_FORCE_REMOVE=true "$HELPER" remove "$BRANCH_NAME" --force 2>/dev/null || true
else
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
fi

git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
git branch -D "$BRANCH_NAME" 2>/dev/null || true
```

Cleanup failures are non-fatal — the PR is already merged.

Deferred ownership expires even while the owning runtime lives (GH#32528):
interactive TUIs host many sequential full-loops for hours or days. A live
owner's post-merge lease ends after `WORKTREE_DEFERRED_OWNER_MAX_HOURS`
(default 4) or as soon as the same session registers a newer worktree. Expiry
releases only the exact `post-merge-cleanup` registry claim; active-cwd,
dirty-content, open-PR, and merge-proof guards still decide removal. On macOS
the async cleanup helper starts under `setsid` so launchd's process-group
teardown at pulse exit cannot kill a run midway.

Deferred ownership expires even while the owning runtime lives (GH#32528):
interactive TUIs host many sequential full-loops for hours or days. A live
owner's post-merge lease ends after `WORKTREE_DEFERRED_OWNER_MAX_HOURS`
(default 4) or as soon as the same session registers a newer worktree. Expiry
releases only the exact `post-merge-cleanup` registry claim; active-cwd,
dirty-content, open-PR, and merge-proof guards still decide removal. On macOS
the async cleanup helper starts under `setsid` so launchd's process-group
teardown at pulse exit cannot kill a run midway.

## Compact Recovery Archives

Use [`../scripts/worktree-archive-helper.md`](../scripts/worktree-archive-helper.md) for the standalone archive, restore, list, verify, and retention commands. The helper preserves local commits, tracked/staged changes, bounded untracked files, and exact base metadata under `~/.aidevops/recovery/archives/`.

Pulse cleanup invokes the helper for attributable stale/failed workers,
terminal issue or PR worktrees, and generated auto/review worktrees after their
retention window. It verifies each archive before removing the full worktree;
local commits, dirty patches, bounded untracked state, and available failure
context remain restorable. Audit rows use `mode=compact-archive`, and async
cleanup reports removed, archived, and failed-archive totals.

Unattributed worktrees with no open head PR are retained for at least
`WORKTREE_UNATTRIBUTED_RETENTION_DAYS` (default 14) before verified compact
archival and removal. Their archives are stored under an `unattributed` target
rather than being falsely assigned to an issue or PR.

Full worktrees remain required for live owners/sessions/processes, recent worker
metrics, security or forensics markers/labels, repeated zero-session failures,
unclear repository/task attribution, remote policy lookup failures, and archive
creation or verification failures.

Terminal branch PR cleanup carries the PR number from the verified lookup;
timestamp-only branch names do not need an embedded issue number. Any open PR
for the same head vetoes terminal cleanup. PR retention labels and any parsed
branch issue's retention labels must both permit archival.

## Unregistered and third-party worktrees

The bounded central scan also considers linked worktrees whose canonical repo is
absent from `repos.json`. It checks registry ownership, open processes and local
forensics markers before classifying each path. GitHub PRs are looked up against
`upstream` before `origin`, by head branch; successful lookups are cached per
worktree for one UTC day. A failed lookup is not treated as a missing PR. The
pass skips entirely when the GraphQL budget is below the cleanup floor (100).

Open PRs are always retained. Unsent local work on an open PR generates at most
one `thirdparty-open-pr-unsent-work` row per worktree per day. Closed/merged PRs
are eligible immediately; branches without a PR become eligible only after
`WORKTREE_UNREGISTERED_MAX_AGE_DAYS` (default 30), measured from Git HEAD
reflog, index and last commit, not the enclosing directory timestamp. Unique
work must be preserved by a verified compact archive before native Git removal.
Missing canonical repositories use a bounded file-level archive and recoverable
trash, never permanent deletion. Unreadable state or failed archive/guard leaves
the directory in place.

Rollout defaults to **report-only** (`WORKTREE_UNREGISTERED_APPLY=0`). Each
decision emits a `thirdparty` row and the pass emits a summary with eligible,
candidate_bytes, removed, archived and kept_open_pr counts. Enable apply with
`WORKTREE_UNREGISTERED_APPLY=1` only after reviewing a clean report cycle.

## Abandoned central test fixtures

The API-free cleanup pass also recognises legacy `tmp.<random>-feature-auto-*`
fixtures in the configured central worktree base, independently of `repos.json`.
It requires the exact bounded fixture file shape, a missing OS-temporary
canonical repo, a minimum 30-minute age, and clear ownership/process checks.
Symlinks, extra files, forensics markers, live roots, and uncertain inspection
preserve the directory. Eligible fixtures go to recoverable trash only, never a
permanent-delete fallback. The `central-fixtures` log row reports eligible count,
candidate bytes, moved count, and skipped count. Test producers must set their
own `AIDEVOPS_WORKTREE_BASE_DIR` and remove it in teardown.

## Manual Cleanup (interactive sessions)

```bash
# Merge through the lifecycle helper (required from inside a worktree)
full-loop-helper.sh merge PR_NUMBER OWNER/REPO --squash

# Return to canonical repo and pull
CANONICAL_DIR="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
cd "$CANONICAL_DIR"
git fetch origin main

# Remove merged worktrees
worktree-helper.sh clean
```

`worktree-helper.sh clean` removes worktrees whose branches have been merged, archiving them recoverably first; add `--auto` to skip the confirmation prompt. Run from the canonical repo (on `main`). If unavailable: `git worktree prune` only removes stale metadata; never delete worktree directories manually.

## Bulk Remote Branch Cleanup

Use the aidevops CLI route when the remote has accumulated old worker/worktree branches:

```bash
aidevops cleanup remote-branches              # dry-run audit
aidevops cleanup remote-branches --apply      # delete safe candidates
aidevops cleanup branches --repo ~/Git/aidevops --remote origin
```

The command deletes only branches with safety evidence: merged to the default branch or linked to a merged PR, with no open PR and no active local worktree. Unmerged branches are reported as `review` and are not deleted by default.

## Local Branch Cleanup

Use `aidevops cleanup local-branches` for a dry-run audit of local branches, or `aidevops cleanup local-branches --apply` to remove safe candidates. To inspect one branch, add `--branch NAME`. A full scan lists open PRs once per cache window (`AIDEVOPS_LOCAL_BRANCH_CLEANUP_OPEN_TTL_S`, default 60s) and caps closed-PR lookups with `--max-lookups N` (default 500); branches beyond the budget are kept with `lookup budget exhausted`, so rerun to continue a large backlog. Worktree `remove` and `clean` run single-branch cleanup automatically after removing a worktree; a refused cleanup preserves the branch and does not fail worktree removal.

Only branches with no open PR and no active worktree are eligible. Their exact tip must be an ancestor of the remote default branch or match a merged PR's head SHA. Ref deletion uses an atomic SHA lease from an isolated linked worktree and logs the deleted branch and SHA for recovery. Failed GitHub evidence checks preserve branches rather than guessing whether they merged.

## See Also

- `workflows/git-workflow.md` — full worktree lifecycle
- `reference/session.md` — session and worktree conventions
- `full-loop.md` Step 4.9 — worker self-cleanup specification
