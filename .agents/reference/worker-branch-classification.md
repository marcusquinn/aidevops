<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worker Branch Classification (t2980)

How the pulse decides whether a worker "produced output" — and where the
classification can lie about which branch the worker was actually on.

This document maps the full dispatch → exit chain and names three concrete
failure modes that produce `branch=main` (or `branch=develop`)
`worker_branch_orphan` log lines even when the worker did successful work
on a feature branch. It is the post-mortem companion to t2899
(`reference/worker-diagnostics.md` Phase 5) which fixed the *signal-2
false-positive* slice; the modes below are the residual slice.

## The dispatch chain

The worker spawn path is a six-step chain. Each step has one job and
exactly one input that it threads forward:

1. `pulse-dispatch-worker-launch.sh::dispatch_with_dedup` — receives the
   issue number and `repo_path` (canonical repo, always on default branch).
2. `_dlw_precreate_worktree(issue_number, repo_path)` — tries to create
   `feature/auto-<ts>-gh<N>` linked to `repo_path`. Sets
   `_DLW_WORKTREE_PATH` / `_DLW_WORKTREE_BRANCH` on success. **Always
   returns 0** (line 340) — failure is logged but not propagated.
3. `_dlw_nohup_launch(...)` — composes the worker `env` invocation. Two
   things to track:
   - Sets `WORKER_WORKTREE_PATH` / `WORKER_WORKTREE_BRANCH` env vars
     **only** when pre-creation succeeded (line 587-592).
   - Passes `--dir "${worker_worktree_path:-$repo_path}"` to the
     headless runtime (line 602) — **the smoking-gun fallback**. If
     pre-creation silently failed, `--dir` resolves to `$repo_path`,
     which is the canonical repo on the default branch.
4. `headless-runtime-helper.sh cmd_run` → `_cmd_run_prepare` — sets
   `_WORKER_WORKTREE_PATH=$work_dir` and stores `work_dir` in the EXIT
   trap closure. **Crucially, this function does NOT create or check a
   worktree**; it only records `work_dir` for later inspection. (The
   issue body for #21273 hypothesised that `_cmd_run_prepare` creates a
   worktree — that hypothesis is falsified.)
5. The OpenCode/Claude session runs. The worker may move the cwd, check
   out a different branch, create its own worktree via
   `worktree-helper.sh add`, merge a PR, or do all four. None of this
   updates `work_dir`.
6. `_cmd_run_finish` (EXIT trap) → `_worker_produced_output(work_dir)`
   reads `git rev-parse --abbrev-ref HEAD` **inside `work_dir`**, the
   path captured at step 4. This is a one-shot snapshot, not a
   follow-the-worker check.

The classification produced in step 6 is what populates the
`[lifecycle] worker_branch_orphan session=… branch=… work_dir=…` line at
`headless-runtime-helper.sh:1336`.

## Three failure modes

### Mode A — Silent pre-creation failure → fallback to canonical repo

**Symptom.** `branch=main` (or the repo's default branch) on a worker
that produced no PR.

**Cause.** `_dlw_precreate_worktree` returned 0 (the silent-fail
contract on line 340) because `worktree-helper.sh add` produced output
that path-regex extraction couldn't parse, OR the canonical repo was
in a state that blocked worktree creation. The `WORKER_WORKTREE_PATH`
env var is unset, so the worker enters the canonical repo on the
default branch via the `${worker_worktree_path:-$repo_path}` fallback.

**Evidence.** Look for the line
`[dispatch_with_dedup] Warning: worktree pre-creation failed for #N`
immediately preceding the dispatch in `~/.aidevops/logs/pulse.log`. If
present, the subsequent `branch=main` classification for that issue is
this mode.

**Falsifying check.** `git -C <repo_path> worktree list | grep gh<N>`
at the time of the failure should show **no** matching worktree.

### Mode B — Worker creates its own worktree, dispatcher's snapshot stays stale

**Symptom.** `branch=main`, but a feature-branch worktree for the same
issue exists, AND a PR was successfully created.

**Cause.** Pre-creation succeeded, `WORKER_WORKTREE_PATH` was set, but
the worker (legitimately) created a different worktree — for example,
the LLM read the contradictory clause in the V6 contract
(`headless-runtime-lib.sh:418-460` says both "Do NOT call
worktree-helper.sh" AND "If WORKER_WORKTREE_PATH not set, create a
worktree via worktree-helper.sh add"). The worker `cd`s into its own
worktree, opens a PR from the new branch, exits cleanly. `work_dir` in
the EXIT trap closure still points at the dispatcher-allocated path,
which may have been left on `main` (or never had a commit).

**Canonical evidence.** `~/.aidevops/logs/worker-20967.log` — worker
created `aidevops-bugfix-gh-20967-caller-permissions/` worktree
manually, merged PR #21012 from there, exited successfully. The
`worker_branch_orphan` line classified `branch=main` because the
dispatcher's `work_dir` snapshot was the wrong worktree.

**Falsifying check.** `git worktree list --porcelain` shows two
worktrees with `gh-?20967` in the branch name; PR for that issue is
merged. The "orphan" claim is false.

### Mode C — Snapshot is wrong by design after worker moves

**Symptom.** `branch=main` or `branch=<default>` on a worker that did
real work, with no second worktree.

**Cause.** The worker started in the pre-created worktree, did its
work, ran `full-loop-helper.sh merge` on its PR — which checks out the
default branch back in the same worktree to verify the merge — and
exited. `_worker_produced_output` then sees the post-merge state:
HEAD on default branch, working tree clean. It cannot distinguish
"worker did everything right and just merged" from "worker never left
main".

**Why this is a design issue, not a fix-able bug.** The function
inspects state at the wrong time. By the time the EXIT trap fires, the
branch the worker did work on may have been deleted by the merge step.
A point-in-time snapshot of HEAD will lie unless we also check
`git reflog` or PR state.

**Differentiator vs Mode A.** A Mode-C orphan has a corresponding
merged PR within the worker's session window. A Mode-A orphan has
nothing.

## What's already mitigated

t2899 (PR #21045) added two guards in `_worker_produced_output`:

- Default-branch + zero-ahead state returns `noop` instead of `pr_exists`.
- Diagnostic line `[lifecycle] worker_branch_orphan session=… branch=…
  target_branch=… final_head=… ahead_count=… work_dir=…` is logged
  every time signal-2 (`pr_exists` from the branch reading) would have
  fired.

These caught the worst case (false `pr_exists` claims). They do not
fix the three modes above — those still log the wrong `branch=` value.

## Recommended fixes (filed separately)

### Fix A — Make `_dlw_precreate_worktree` failure visible

Drop the unconditional `return 0` at line 340. Have the function
return non-zero on path-extraction failure, and have `_dlw_nohup_launch`
either:

1. Skip the worker entirely (preferred — fail fast, observable in
   `pulse-stats.json` as a new `worktree_precreation_failed_count`
   counter), OR
2. Treat the canonical repo as a hard error in the `--dir` argument:
   drop the `:-$repo_path` fallback. Workers should never be dispatched
   into the canonical repo on default.

Plus an observability increment so we can see how often this happens
in production.

### Fix B — `_worker_produced_output` should follow the worker, not trust `work_dir`

Replace the dispatch-time `work_dir` snapshot with a discovery step at
classification time:

```sh
# Pseudocode
candidate=$(git -C "$repo_path" worktree list --porcelain \
  | awk -v n="$WORKER_ISSUE_NUMBER" '
    /^worktree / { p=$2 }
    /^branch / && $2 ~ "gh-?" n { print p; exit }')
[[ -z "$candidate" ]] && candidate="$work_dir"
branch=$(git -C "$candidate" rev-parse --abbrev-ref HEAD 2>/dev/null)
```

This handles Modes B and C: any worktree the worker created (or moved
into) with the issue number in its branch name will be discovered. The
`work_dir` fallback preserves current behaviour when no
issue-numbered worktree exists.

### Fix C — Resolve the V6 contract contradiction (IMPLEMENTED — t2983 / GH#21355)

**Status:** Implemented. Path 1 (recommended) chosen.

**Path taken:** Pre-creation must always succeed; worker never creates worktrees.

**What changed (PR for GH#21355):**

1. `headless-runtime-lib.sh::append_worker_headless_contract` — contract bumped
   from V6 to V7. The contradictory "If not set, create a worktree yourself via
   `worktree-helper.sh add`" clause is removed. The prohibition is now
   unconditional with rationale: "Pre-creation is guaranteed by the dispatcher
   (GH#21353 / t2983 Fix C). If WORKER_WORKTREE_PATH is unset, the headless
   runtime has already aborted — you are not running."

2. `headless-runtime-helper.sh::_cmd_run_prepare` — early guard added: if
   `WORKER_ISSUE_NUMBER` is set (worker dispatch) but `WORKER_WORKTREE_PATH` is
   unset, the function logs a fatal error and returns non-zero immediately.
   This turns a silent mis-dispatch into an observable error.

3. `.agents/scripts/tests/test-headless-contract-clarity.sh` — new test that
   verifies the emitted contract does NOT contain both "Do NOT call" and
   "create a worktree" clauses simultaneously, and that V7 is the active
   contract version.

**Depends on:** Fix A (GH#21353, t2981) — merged PR #21359 on 2026-04-27.
Without Fix A's non-silent pre-creation failure, WORKER_WORKTREE_PATH could
still be unset at worker launch time. Fix C's guard in `_cmd_run_prepare`
catches this as an explicit fatal rather than a silent wrong-directory error.

## Diagnosing in production

| Log line | Likely mode | Next check |
|----------|-------------|-----------|
| `Warning: worktree pre-creation failed for #N` ahead of dispatch | A | No worktree exists for `#N` |
| `branch=main`, no PR created, no warning | A or pulse anomaly | `git worktree list \| grep gh<N>` |
| `branch=main`, PR exists and merged from `gh-?N` branch | B or C | Compare PR head ref to `work_dir` |
| `branch=main`, PR exists from feature branch but worktree is gone | C | `git reflog` in `work_dir` |
| `branch=develop` or other non-default branch unrelated to `<N>` | Pre-created worktree drift | Check repo's default-branch config |

## Cross-references

- Phase 5 / t2820 — log-tail-based reclassification of `worker_failed`:
  `reference/worker-diagnostics.md:375`
- t2899 — default-branch guard on signal 2: PR #21045
- Headless contract: `headless-runtime-lib.sh::append_worker_headless_contract`
- Pre-creation: `pulse-dispatch-worker-launch.sh::_dlw_precreate_worktree`
- Classification: `headless-runtime-helper.sh::_worker_produced_output`
- Orphan log emitter: `headless-runtime-helper.sh::_handle_worker_branch_orphan`
