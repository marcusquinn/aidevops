<!-- aidevops:brief-schema=v2 -->

# t18554: Release: unshallow the release control worktree before lane reservation so a shallow store cannot strand the release lane

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** The maintainer asked for a release. The standard-tier release child's first `aidevops release patch 33042 incremental` failed on a raw `git describe` error, because the shared store had been made shallow by the claim-path bug fixed in GH#33033. The failure also left the release lane reserved. The primary healed the store with one linked-worktree unshallow, and v3.37.31 then tagged normally. Following ambient-capture policy, this follow-up was filed as GH#33069 for auto-dispatch.

## What

Before any lane interaction, `aidevops release` detects a shallow object store. It heals it with a bounded `git fetch --unshallow --tags origin` in its own control linked worktree, or, when healing is disabled or fails, stops with a `RELEASE_SHALLOW_STORE` error and the manual recovery command. It never writes the lane in that case. The base-tag `git describe` failure also prints an actionable `RELEASE_BASE_TAG_UNRESOLVED` line instead of only git's `fatal:` text.

## Why

- `_full_loop_release_prepare_new` (`.agents/scripts/full-loop-release-helper.sh:325-398`) runs `git describe --tags --match 'v[0-9]*' --abbrev=0 "$snapshot"` at L346 and returns 1 with no explanation when the tag is unreachable, which is what happens on a shallow store.
- `_full_loop_release_start_new` (L623-675) has already called `release_lane_acquire` (L667) by then. The lane stays `phase:"reserved"` with a dead executor, the rerun exits 8, and `aidevops release recover-reservation` refuses until the five-minute window passes.
- Evidence from 2026-09-29:
  - the first run exited 1 after 25s with `fatal: No tags can describe '2523f44c…'`, when the store held 19 reachable commits;
  - `git fetch --unshallow --tags origin` from a linked worktree took 18s, after which `describe` returned `v3.37.30` and `rev-list --count origin/main` returned 25524;
  - release v3.37.31 then tagged after one `recover-reservation`.
- `REPO_ROOT` is a disposable control linked worktree (`_full_loop_release_prepare_control_worktree`, L88-111), so unshallowing there is the documented safe route in `.agents/reference/git-hygiene.md`, and the canonical checkout is never touched.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: one guarded helper function and one call site in a release script, closely modelled on an existing function (`_check_and_handle_shallow_clone`), plus stub-driven test scenarios in an existing harness. Not `tier:simple`, because the call must sit before every lane path (competing-lane guard, persisted-intent recovery and acquire), and the test stub needs new cases so it does not pass vacuously.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/full-loop-release-helper.sh:325-348,623-634`:
  - Add `_full_loop_release_ensure_full_history` just above `_full_loop_release_prepare_new`, modelled on `_check_and_handle_shallow_clone` in `.agents/scripts/full-loop-helper-commit.sh:1263-1302`.
  - Call it as the first statement of `_full_loop_release_start_new`, before `_full_loop_release_guard_competing_lane` (L634).
  - At L346, replace the bare `|| return 1` with a short block that prints `RELEASE_BASE_TAG_UNRESOLVED snapshot=<sha> shallow=<value>` and the recovery hint, then returns 1.
- `EDIT: .agents/scripts/tests/test-full-loop-release-helper.sh:18-47`:
  - Model on the existing stubbed scenario at L160-180.
  - Add `*--is-shallow-repository*) printf '%s\n' "${FAKE_SHALLOW:-false}" ;;` and `*fetch\ --unshallow*) exit "${FAKE_UNSHALLOW_EXIT:-0}" ;;` cases to the `git` stub, which already logs every call to `GIT_CALL_LOG`.
  - Add the three scenarios listed in Implementation Steps. Each scenario needs a fresh `LANE_STATE_FILE` / `LANE_HEAD_FILE`.
- `EDIT: .agents/workflows/release.md:321-330`: add a Troubleshooting row: "`fatal: No tags can describe` or `RELEASE_SHALLOW_STORE`" → "The shared store is shallow. Run `git fetch --unshallow --tags origin` from any linked worktree, never canonical, then rerun the same release command."
- `EDIT: .agents/reference/git-hygiene.md:88-98`: under "Root Cause", add one sentence saying that `aidevops release` also auto-unshallows through its control worktree, and that `AIDEVOPS_SHALLOW_UNSHALLOW=0` disables it.

### Complete Write Surface

- **Callers/readers:** `aidevops.sh` `release` dispatch invokes `.agents/scripts/full-loop-release-helper.sh`. Its `main` (L677-773) calls `_full_loop_release_start_new` (L769). Operators and the standard-tier release child read its stdout markers, as described in `.agents/workflows/release.md`.
- **Writers/mutation paths:**
  - The new fetch writes objects, tags and the removal of `shallow` into the shared store through the control worktree `REPO_ROOT`.
  - The lane writes (`release_lane_acquire`, `release_lane_recover_reservation` in `.agents/scripts/release-lane-helper.sh`) are unchanged and are now reached only after a full-history check.
- **Schemas/config:** reuses the existing `AIDEVOPS_SHALLOW_UNSHALLOW` switch from `.agents/scripts/full-loop-helper-commit.sh`, and adds `AIDEVOPS_RELEASE_UNSHALLOW_TIMEOUT_S` (default 600, validated `^[1-9][0-9]*$`, falling back to the default when invalid). Both are documented in the function comment.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/full-loop-release-helper.sh` to `~/.aidevops/agents/scripts/`, and the `aidevops release` CLI runs the deployed copy.
- **Migrations/backfills:** N/A because there is no persisted state or format change. Existing shallow stores heal on the next release run.
- **Cleanup/rollback paths:** revert the PR touching `.agents/scripts/full-loop-release-helper.sh`. The helper then fails at `git describe` as it does today. Unshallowed stores stay full-depth, which is harmless.
- **Existing verification/tests:** `.agents/scripts/tests/test-full-loop-release-helper.sh`, `.agents/scripts/tests/test-release-lane-reservation.sh`, `.agents/scripts/tests/test-release-lane.sh`, `.agents/scripts/tests/test-full-loop-release-reconcile.sh`.

### Implementation Steps

1. Write `_full_loop_release_ensure_full_history` (explicit `return 0`/`return 1`, `local` variables):
   - Read `git -C "$REPO_ROOT" rev-parse --is-shallow-repository`. Anything other than `true`, including empty stub output, returns 0 without a fetch.
   - If `${AIDEVOPS_SHALLOW_UNSHALLOW:-1}` is `0`, print `RELEASE_SHALLOW_STORE action=disabled` and `Run from a linked worktree: git fetch --unshallow --tags origin`, then return 1.
   - Otherwise run `timeout_sec "$timeout_s" git -C "$REPO_ROOT" fetch --unshallow --tags origin` and re-read the shallow state. Print `RELEASE_SHALLOW_STORE action=healed` and return 0, or print `RELEASE_SHALLOW_STORE action=failed` with the manual command and return 1.
2. Insert `_full_loop_release_ensure_full_history || return 1` as the first statement of `_full_loop_release_start_new`.
3. Add the L346 diagnostic block.
4. Add the stub cases and three test scenarios:
   - shallow and healable: `fetch --unshallow --tags origin` appears in `git.log` before `worktree add --detach`, and the version-manager stub runs;
   - `AIDEVOPS_SHALLOW_UNSHALLOW=0`: non-zero exit, `action=disabled` printed, and no `LANE_STATE_FILE`;
   - `FAKE_UNSHALLOW_EXIT=1`: non-zero exit, `action=failed`, and no `LANE_STATE_FILE`.
5. Update the two docs and run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** the fetch runs before any lane compare-and-swap, so it cannot race lane ownership. Concurrent fetches into the same store are serialized by git's own ref and shallow lock files. A concurrent unshallow from another worktree makes the re-check pass.
- **Migration/rollback:** no persisted state. Rollback is a revert.
- **Mixed-version/backward compatibility:** full-depth stores see one extra read-only `rev-parse` and no fetch. `AIDEVOPS_SHALLOW_UNSHALLOW` keeps the same meaning as in `.agents/scripts/full-loop-helper-commit.sh`. Older CLI copies keep today's behaviour.
- **Idempotency/retry:** a rerun on a healed store skips the fetch. A failed unshallow leaves no lane state, so a rerun needs no `recover-reservation`.
- **Partial failure/recovery:** a timed-out or interrupted fetch leaves the store shallow or partially deepened. The re-check still reports shallow, so the helper fails closed with `action=failed` before any lane write.

### Complexity Impact

- **Target function:** `_full_loop_release_start_new` in `.agents/scripts/full-loop-release-helper.sh`
- **Current line count:** 53 lines (L623-675; threshold: 100 lines for function-complexity)
- **Estimated growth:** +1 line (one guarded call)
- **Projected post-change:** 54 lines (54% of threshold). The new helper is about 30 lines, and `_full_loop_release_prepare_new` grows by about 5 lines to about 79.
- **Action required:** none beyond keeping the new logic in its own function.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/full-loop-release-helper.sh .agents/scripts/tests/test-full-loop-release-helper.sh
bash .agents/scripts/tests/test-full-loop-release-helper.sh
bash .agents/scripts/tests/test-release-lane-reservation.sh
bash .agents/scripts/tests/test-release-lane.sh
bash .agents/scripts/tests/test-full-loop-release-reconcile.sh
```

- **Surface mapping:**
  - `shellcheck` covers both changed scripts.
  - `test-full-loop-release-helper.sh` covers the three new scenarios (heal, disabled, failed). The two failure scenarios prove there is no lane write, which covers the partial-failure and idempotency hazards. The existing scenarios prove the full-depth path is unchanged, which covers the mixed-version hazard.
  - `test-release-lane-reservation.sh` and `test-release-lane.sh` prove lane reservation and recovery semantics are unchanged (concurrency hazard).
  - `test-full-loop-release-reconcile.sh` proves the status/reconcile paths are unaffected.
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release workflow YAML changes.

### Scope Boundaries

**Hard boundaries:**

- Never run the unshallow or any other fetch through the canonical checkout path; use `REPO_ROOT` only after control-worktree setup.
- Do not change the five-minute reserved-lane recovery window or any lane state transitions in `.agents/scripts/release-lane-helper.sh`.
- Do not add unshallowing to `status`, `reconcile` or other read-only subcommands.
- Do not change `.github/workflows/` release publication.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/full-loop-release-helper.sh`
- `.agents/scripts/tests/test-full-loop-release-helper.sh`
- `.agents/workflows/release.md`
- `.agents/reference/git-hygiene.md`
- `TODO.md`

## Acceptance Criteria

- [ ] On a shallow store, the release helper runs `fetch --unshallow --tags origin` in its control worktree before creating the release worktree, then continues.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-release-helper.sh"
  ```

- [ ] The guard runs before any lane interaction.

  ```yaml
  verify:
    method: codebase
    pattern: "_full_loop_release_ensure_full_history"
    path: ".agents/scripts/full-loop-release-helper.sh"
  ```

- [ ] Negative/regression:
  - disabled or failed healing exits non-zero with `RELEASE_SHALLOW_STORE` and writes no lane state;
  - full-depth stores run no fetch;
  - lane reservation, recovery and reconcile tests pass unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-release-lane-reservation.sh && bash .agents/scripts/tests/test-release-lane.sh && bash .agents/scripts/tests/test-full-loop-release-reconcile.sh"
  ```

- [ ] Changed-file lint is clean: `shellcheck .agents/scripts/full-loop-release-helper.sh .agents/scripts/tests/test-full-loop-release-helper.sh`

## Context & Decisions

- The helper self-heals rather than only failing clearly. Commit-and-PR already auto-unshallows the same way, the fetch took 18s on the real store, and release is operator-attended, so healing avoids a second interactive round trip.
- The guard sits before the competing-lane guard rather than inside `_full_loop_release_prepare_new`, because every path that can write or recover the lane starts in `_full_loop_release_start_new`.
- The L346 diagnostic stays as defence in depth for non-shallow causes of an unresolvable base tag (for example missing tags), which the guard does not cover.

## Relevant Files

- `.agents/scripts/full-loop-release-helper.sh:88-111,325-398,623-675` — control worktree, prepare, start
- `.agents/scripts/full-loop-helper-commit.sh:1263-1302` — reference auto-unshallow pattern
- `.agents/scripts/tests/test-full-loop-release-helper.sh:18-47,160-180` — git stub and reference scenario
- `.agents/workflows/release.md:319-330` — troubleshooting table
- `.agents/reference/git-hygiene.md:55-98` — shallow recovery guidance
