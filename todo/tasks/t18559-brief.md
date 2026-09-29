<!-- aidevops:brief-schema=v2 -->

# t18559: Local-branch cleanup: list open PRs once per scan and cap per-run GitHub lookups

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** After the maintainer-authorized v3.37.31 release, the session tested the new `aidevops cleanup local-branches` helper from GH#33030 / t18552 (PR #33042). The classifications were correct and the scoped `--apply` runs worked. A full-repository dry-run, though, was far too slow and API-heavy to finish. Following ambient-capture policy, this was filed as GH#33077 for auto-dispatch.

## What

A full-repository `aidevops cleanup local-branches` run lists open PRs once per TTL window instead of once per branch. It caps closed-PR `head=` lookups per run with `--max-lookups N`, so a large backlog clears over bounded, repeatable runs. Single-branch runs (`--branch NAME --apply`) used after worktree removal keep their output and safety.

## Why

- `pr_evidence` (`.agents/scripts/local-branch-cleanup-helper.sh:89-124`) fetches `pulls?state=open&per_page=100&page=N` (L97-107) on every call. `scan_branch` (L189-218) calls it once per local ref (L231-233), so a scan re-lists the same open PRs thousands of times.
- `active_branch` (L126-131) also runs `git worktree list --porcelain` once per branch.
- Evidence from 2026-09-29 (aidevops repo: 3,975 local branches, 12 open PRs):
  - the dry-run scanned 199 branches in 555s (about 2.8s per branch) through `gh-transport-governor.py`;
  - a full dry-run would take about 3 hours, and `--apply` about as long again;
  - that is roughly 8,000 REST calls against the 5,000/hour budget shared with pulse and workers.
- Scoped runs worked:
  - `--branch 25708 --apply` deleted a squash-merged branch (audit seq 22253);
  - `--branch auto-20260428-030312-gh3305 --apply` deleted an ancestry-merged branch (seq 22254);
  - `--branch 25710 --apply` kept an unmerged branch.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: a caching refactor inside one helper plus one bounded option. The safety semantics must be preserved exactly (fail-closed evidence, pre-delete recheck, lease), and the tests must prove the call count. Not `tier:simple`, because the cache and TTL interact with the mutation-time recheck in `delete_branch`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/local-branch-cleanup-helper.sh:13-25,89-131,159-218`:
  - add globals `OPEN_PR_REFS`, `OPEN_PR_STATUS`, `OPEN_PR_LOADED_AT`, `MAX_LOOKUPS`, `LOOKUPS` and `WORKTREES_CACHE`, plus counters for the summary line;
  - add `load_open_pr_refs`, which moves the L97-108 pagination and fail-closed checks into one loader;
  - in `pr_evidence`, reload only when the cache is older than `AIDEVOPS_LOCAL_BRANCH_CLEANUP_OPEN_TTL_S` (default 60, validated `^[1-9][0-9]*$`, invalid values falling back to the default);
  - count closed-PR queries (L112-121) against `MAX_LOOKUPS`;
  - make `active_branch` use the scan cache, but give `delete_branch` (L166) an uncached read;
  - add `--max-lookups N` to `parse_args` and `usage`, and print a final `summary` line from `main`.
- `EDIT: .agents/scripts/tests/test-local-branch-cleanup-helper.sh:55-88`: model on the existing stubbed dry-run and apply assertions. The `gh` stub appends `$*` to `$ROOT/gh-calls.log`.
- `EDIT: .agents/workflows/worktree-cleanup.md:148-150`: document `--max-lookups`, the TTL variable, and "rerun to continue a large backlog".

### Complete Write Surface

- **Callers/readers:**
  - `aidevops cleanup local-branches` runs the deployed helper.
  - `.agents/scripts/worktree-helper-cmds.sh:342-343` and `.agents/scripts/worktree-clean-lib.sh:1593-1594` invoke `--branch <name> --apply` after worktree removal and only check the exit status.
  - Operators read stdout lines (`would-delete`, `keep`, `deleted`, `failed`, and the new `summary`).
- **Writers/mutation paths:** `delete_branch` (L159-187) is unchanged: transport worktree, mutation-time active and open-PR recheck, SHA-leased `update-ref -d`, then the audit log.
- **Schemas/config:** new CLI option `--max-lookups N` (default 500), new env var `AIDEVOPS_LOCAL_BRANCH_CLEANUP_OPEN_TTL_S` (default 60), and one new `summary` stdout line. The existing `AIDEVOPS_LOCAL_BRANCH_CLEANUP_SKIP_GH` is unchanged.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/local-branch-cleanup-helper.sh` to `~/.aidevops/agents/scripts/`.
- **Migrations/backfills:** N/A because there is no persisted state.
- **Cleanup/rollback paths:** revert the PR touching `.agents/scripts/local-branch-cleanup-helper.sh`. The helper returns to per-branch listing, which is slower but equally safe.
- **Existing verification/tests:** `.agents/scripts/tests/test-local-branch-cleanup-helper.sh`.

### Implementation Steps

1. Extract the open-PR pagination into `load_open_pr_refs`. It must keep the ≤10-page limit, the array-type and count checks, and a result of `unavailable` on any failure or on exceeding the page limit.
2. In `pr_evidence`, answer the open check from `OPEN_PR_REFS`, reloading when the TTL has expired. Keep the closed-PR loop, incrementing `LOOKUPS` per request. When `LOOKUPS` reaches `MAX_LOOKUPS` before a needed lookup, set `PR_STATUS=budget`.
3. In `scan_branch`, map `budget` to `keep <branch> lookup budget exhausted`, and keep ancestry-merged branches eligible, since they need no closed-PR lookup.
4. Cache the worktree list for the scan-time `active_branch`, and use a fresh read in `delete_branch`.
5. Print `summary scanned=<n> would-delete|deleted=<n> kept=<n> lookups=<n> budget_exhausted=<n>` at the end of `main`, and keep the existing exit codes.
6. Tests:
   - add the gh-call log;
   - after the existing full dry-run (L67), assert `rg -c 'pulls\?state=open&' "$ROOT/gh-calls.log"` equals 1;
   - add a `--max-lookups 0` dry-run that asserts `would-delete merged` and `keep squash lookup budget exhausted`;
   - keep all existing assertions.
7. Update the workflow doc and usage text, then run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** a PR opened after the cache loads could be missed for up to TTL seconds. The mutation-time lease (`update-ref -d <ref> <sha>`) still refuses deletion if the ref moved. The default 60s TTL matches the scan-to-delete window of the current per-branch design, and `delete_branch` still rechecks.
- **Migration/rollback:** there is no persisted state, so rollback is a revert.
- **Mixed-version/backward compatibility:**
  - existing output lines are unchanged, and `summary` is additive;
  - worktree callers check only the exit status;
  - the default `--max-lookups 500` still lets single-branch runs perform their one lookup.
- **Idempotency/retry:** rerunning continues the backlog. Deleted refs report `absent`, and budget-kept branches are reconsidered on the next run.
- **Partial failure/recovery:** a failed open-PR load marks everything `github evidence unavailable` and nothing is deleted, as today. Deleted refs remain recoverable from the audit log's SHA.

### Complexity Impact

- **Target function:** `pr_evidence` in `.agents/scripts/local-branch-cleanup-helper.sh`
- **Current line count:** 36 lines (L89-124; threshold: 100 lines for function-complexity)
- **Estimated growth:** about −8 lines once pagination moves into `load_open_pr_refs` (about 25 lines)
- **Projected post-change:** about 28 lines. `scan_branch` grows by about 2 lines, to about 32, and `main` by about 3 lines, to about 23.
- **Action required:** none.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/local-branch-cleanup-helper.sh .agents/scripts/tests/test-local-branch-cleanup-helper.sh
bash .agents/scripts/tests/test-local-branch-cleanup-helper.sh
```

- **Surface mapping:**
  - `shellcheck` covers both changed scripts.
  - The test proves:
    - the single open-PR listing per scan (the new call-log assertion);
    - the lookup budget (the `--max-lookups 0` scenario);
    - unchanged safety: open and fork PRs kept, unavailable evidence kept, lease refusal, and transport cleanup (the concurrency and partial-failure hazards);
    - the unchanged single-branch apply output relied on by worktree callers (the mixed-version hazard).
- **Broad verification trigger:** Not required. There are no shared config, root tooling or workflow YAML changes.

### Scope Boundaries

**Hard boundaries:**

- Do not relax any deletion criterion: ancestry or merged-PR head SHA, no open PR, not checked out, and lease.
- Do not change `.agents/scripts/worktree-helper-cmds.sh` or `.agents/scripts/worktree-clean-lib.sh` call sites.
- Do not add GraphQL batching or a persistent on-disk cache.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/local-branch-cleanup-helper.sh`
- `.agents/scripts/tests/test-local-branch-cleanup-helper.sh`
- `.agents/workflows/worktree-cleanup.md`
- `TODO.md`

## Acceptance Criteria

- [ ] A full dry-run lists open PRs once per TTL window: the test stub log shows exactly one `pulls?state=open&` call.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-local-branch-cleanup-helper.sh"
  ```

- [ ] `--max-lookups N` bounds closed-PR queries. Branches beyond the budget are kept with `lookup budget exhausted`, and ancestry-merged branches remain eligible.

  ```yaml
  verify:
    method: codebase
    pattern: "--max-lookups"
    path: ".agents/scripts/local-branch-cleanup-helper.sh"
  ```

- [ ] Negative/regression:
  - open and fork PR refs are kept;
  - unavailable GitHub evidence preserves branches;
  - the moved-ref lease refuses deletion;
  - no transport worktree is left registered;
  - single-branch `--branch NAME --apply` output is unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-local-branch-cleanup-helper.sh"
  ```

- [ ] Changed-file lint is clean: `shellcheck .agents/scripts/local-branch-cleanup-helper.sh .agents/scripts/tests/test-local-branch-cleanup-helper.sh`

## Context & Decisions

- The design uses a per-run cache with a TTL instead of dropping the per-branch open-PR check. The original design lists every open PR, to catch fork PRs with the same head ref, and rechecks before mutation. The TTL keeps both properties while making cost proportional to runtime rather than branch count.
- The helper caps lookups per run instead of listing every closed PR in bulk. About 33k closed PRs is roughly 330 pages per run, and bounded incremental runs are resource-aware and restartable.
- The default budget of 500 covers typical repositories in one run, while large backlogs clear over a few runs.

## Relevant Files

- `.agents/scripts/local-branch-cleanup-helper.sh:13-25,89-131,159-241` — globals, usage, evidence, active check, delete, scan, main
- `.agents/scripts/tests/test-local-branch-cleanup-helper.sh:55-109` — gh stub and assertions
- `.agents/workflows/worktree-cleanup.md:146-150` — Local Branch Cleanup docs
- `.agents/scripts/worktree-helper-cmds.sh:342-343`, `.agents/scripts/worktree-clean-lib.sh:1593-1594` — single-branch callers
