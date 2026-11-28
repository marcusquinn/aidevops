<!-- aidevops:brief-schema=v2 -->
## Origin

Found during the interactive full-loop that released v3.39.292 (source PR #40639). Run from the canonical checkout, or from any directory outside a linked worktree, `aidevops release status 40639` printed lane and receipt state, then failed tag discovery:

```text
RELEASE_RECEIPT=published
RELEASE_TIMING phase=release-tag-fetch state=start
BLOCKED by canonical Git guard: canonical worktree mutation via 'git fetch'. Use a linked worktree for edits. ...
RELEASE_TIMING phase=release-tag-fetch state=finish elapsed_seconds=1 result=failed
RELEASE_TIMING phase=release-tag-discovery state=finish elapsed_seconds=1 result=failed
```

This happened twice in one session (once while the lane was `preparing`, once after `terminal/published`). The same command run from a linked worktree completed tag discovery.

## What

Make `aidevops release status <PR>` complete without mutating the canonical checkout, so it never trips the canonical Git guard. `aidevops release --help` documents `status` as read-only.

## Why

Status is the documented inspect path for exit-8 (pending) releases, and the release-lane session-bus notices point operators at it. When it fails in the default location, operators either misread the failure or retry from ad-hoc worktrees.

## Tier

`tier:standard`. This is a narrow fix in one function's read-only path. The approach choice is bounded (below) and needs no new infrastructure.

## How (Approach)

**Root cause (verified):** GH#38741 (`28bf479b73`, "skip control worktree for read-only release status") stopped `status` from creating the release control worktree, so `REPO_ROOT` comes from `_full_loop_release_resolve_repo_root`. That function returns the canonical checkout when the caller is not inside a linked worktree (`.agents/scripts/full-loop-release-helper.sh:22-39`, `:1164-1166`). Tag discovery still begins with `git -C "$REPO_ROOT" fetch origin --tags --quiet` (`.agents/scripts/full-loop-release-reconcile.sh:539`, inside `_full_loop_release_find_tag_for_pr`). `status` reaches that through `_full_loop_release_existing_command` (`full-loop-release-reconcile.sh:1971`). In the canonical checkout the fetch is a ref mutation, and the guard blocks it.

### Files to Modify

- `EDIT: .agents/scripts/full-loop-release-reconcile.sh:522-544` — in `_full_loop_release_find_tag_for_pr`, do not run `git fetch` into a canonical `REPO_ROOT` in `status` mode.
- `EDIT: .agents/scripts/tests/test-full-loop-release-reconcile-discovery.sh` — extend the existing git-stub cases (the `*" fetch origin --tags --quiet"*) return 0 ;;` pattern at ~L269/386/426) with a status-mode case where `fetch` fails as the guard does, asserting that discovery still runs on local refs.

### Complete Write Surface

- **Callers/readers:** `_full_loop_release_find_tag_for_pr` is called from `full-loop-release-reconcile.sh:1971` (status + reconcile), `full-loop-release-helper.sh:318` (new release existing-guard) and `full-loop-release-aggregate-recovery.sh:1138`. Only the `status` path runs without a control worktree. Reconcile, release and recover-aggregate prepare one (`full-loop-release-helper.sh:1166`) and must keep fetching.
- **Writers/mutation paths:** the fetch at `:539` is the only canonical mutation on the status path. `_full_loop_release_recover_lane_tag` (`:552`) may also write `refs/tags/*` via `update-ref` (`:516`). Check whether status reaches it, and keep status read-only there too.
- **Existing verification/tests:** `test-full-loop-release-reconcile-discovery.sh` (git-stub based) and `test-full-loop-release-reconcile-command.sh`.
- **Schemas/config:** none. Output keys (`RELEASE_LANE`, `RELEASE_RECEIPT`, `RELEASE_TAG`, `RELEASE_TIMING`) are unchanged; `rg -n "RELEASE_TAG=" .agents/scripts` lists every consumer.
- **Generated/deployed mirrors:** the deployed copy under the user's aidevops agents directory is refreshed by `setup.sh` / release deploy; no generated files.
- **Migrations/backfills:** N/A because status persists no state; the only release state files (receipt under `_full_loop_release_receipt_path`, lane via `release_lane_read`) are read, not written, on this path.
- **Cleanup/rollback paths:** N/A because the change adds no files, refs or worktrees; reverting the edit to `.agents/scripts/full-loop-release-reconcile.sh` restores the current behaviour.

### Implementation Steps

1. Pick the smallest read-only option that keeps signature verification intact, and record the choice in the PR decisions. Two options:
   - (a) In `status` mode, skip the fetch and run discovery on existing local tags/objects, with one-line notes such as `RELEASE_TAG_FETCH=skipped (read-only status; run reconcile from a linked worktree to refresh)`.
   - (b) Use read-only remote evidence (`git ls-remote --tags origin`) to detect a newer remote tag, and report it without fetching objects.

   Thread the mode through an explicit argument or a variable set by `_full_loop_release_existing_command`. Do not infer it from the cwd.
2. Keep reconcile, release and recover-aggregate fetching exactly as now. They run in the control worktree.
3. Extend the discovery test as described above, then run the verification commands.

### Hazards and Compatibility

- **Concurrency/atomicity:** status must stay non-mutating, so concurrent status calls and a live release executor cannot race on refs. Preserve that.
- **Migration/rollback:** none. This is a read path with no persisted state.
- **Mixed-version/backward compatibility:** keep every existing output key. Add notes rather than renaming fields, because pulse and session-bus routing read `RELEASE_LANE`/`RELEASE_RECEIPT`.
- **Idempotency/retry:** status is replayable. Reconcile must keep refreshing tags so a stale local store cannot hide a new tag.
- **Partial failure/recovery:** when local tags are stale, status must say so and point to `aidevops release reconcile <PR>`. It must not report a wrong tag as authoritative or exit as if discovery failed.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-full-loop-release-reconcile-discovery.sh
bash .agents/scripts/tests/test-full-loop-release-reconcile-command.sh
shellcheck .agents/scripts/full-loop-release-reconcile.sh .agents/scripts/tests/test-full-loop-release-reconcile-discovery.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the discovery test covers the status-mode read-only branch (positive) and the reconcile-mode fetch (regression). The command test covers status/reconcile dispatch and output keys. ShellCheck/linters cover the changed shell files.
- **Broad verification trigger:** Not required. The change is local to one read path in the release reconciler.

### Files Scope

- `.agents/scripts/full-loop-release-reconcile.sh`
- `.agents/scripts/tests/test-full-loop-release-reconcile-discovery.sh`

## Acceptance Criteria

- [ ] `aidevops release status <PR>` run from the canonical checkout performs no `git fetch` or `update-ref` there, completes tag discovery from local evidence, and prints `RELEASE_TAG=<tag>` when the tag is known locally.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-release-reconcile-discovery.sh"
  ```

- [ ] Regression: `reconcile`, new `release` and `recover-aggregate` still fetch tags in their control worktree before discovery; status read-only handling must not reach those modes.

  ```yaml
  verify:
    method: codebase
    pattern: "fetch origin --tags"
    path: ".agents/scripts/full-loop-release-reconcile.sh"
  ```

- [ ] Status output keeps the `RELEASE_LANE`, `RELEASE_EXECUTOR`, `RELEASE_RECEIPT` and `RELEASE_TIMING` keys unchanged.
- [ ] ShellCheck and changed-file linters are clean.

## Context & Decisions

- Not in scope: changing the canonical Git guard. It is correct to block canonical ref mutation; the defect is that a documented read-only command mutates.
- Not in scope: re-adding a control worktree to `status`. GH#38741 removed it deliberately for performance.
- Impact today: cosmetic or operator-confusing only. Publication and receipts were correct (`terminal_receipt: published` for v3.39.292).

## Relevant Files

- `.agents/scripts/full-loop-release-reconcile.sh:522-560` — `_full_loop_release_find_tag_for_pr`
- `.agents/scripts/full-loop-release-reconcile.sh:1942-1975` — `_full_loop_release_existing_command` (status/reconcile entry)
- `.agents/scripts/full-loop-release-helper.sh:22-39,1164-1166` — repo-root resolution and the GH#38741 status skip
