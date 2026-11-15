<!-- aidevops:brief-schema=v2 -->

# t19013: closed-checkpoint dispatch scan must page past the 30 most recently updated closed PRs

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `closed checkpoint scan pagination pulse partial continuation window` → 0 hits — no relevant lessons
- [x] Discovery pass: 1 commit (0d0eb38dc4, GH#38355) / 1 merged PR (#38370) / 0 open PRs touch the target files in last 48h (#38263 touches pulse fork reductions, not this function)
- [x] File refs verified: 6 refs checked, all present at HEAD `0d0eb38dc4`
- [x] Tier: `tier:standard`. Not in `.agents/configs/self-hosting-files.conf`; the stop rule and stamp format are still the worker's choice
- [x] Seeded draft PR decision recorded: skipped. The change is small and the stop-rule choice belongs to the worker

## Origin

- **Created:** 2026-11-15
- **Session:** opencode:gh38355 full-loop closeout
- **Created by:** ai-interactive
- **Conversation context:** This follows up on GH#38355 / PR #38370, released in v3.39.199. The closeout reported that the new closed-checkpoint scan reads one fixed page of closed PRs, and the maintainer asked for that limit to be captured.

## What

`_pmpc_reconcile_closed_checkpoints` must check every worker-branch PR that was closed unmerged since its previous complete scan, within the existing lookback. It must not stop at the 30 most recently updated closed PRs. A closed checkpoint draft must still get `auto-dispatch` back after a burst of closed-PR activity or a long pulse pause.

## Why

`.agents/scripts/pulse-merge-partial-continuation.sh:809` makes one call: `pulls?state=closed&sort=updated&direction=desc&per_page=30`. It has no pagination and no high-water mark. The scan runs only on a fresh traversal (`:806`), on the stale-blocked cadence (`PULSE_STALE_BLOCKED_RECONCILE_INTERVAL`, default 1800s, `.agents/scripts/pulse-wrapper-cycle.sh:960`). Sorting is by `updated_at`, so comments or labels on old closed PRs (release notes, bots) push genuine closures off the page.

Measured on 2026-11-15: this repo had 100 closed-PR updates in about 19h, roughly 5 per hour. A pulse outage of about 6h, such as the GitHub core-quota exhaustion seen during the v3.39.199 release, already exceeds 30 updates. A closure that falls off the page is never revisited. `_pmpc_list_candidates`' available-phase sweep (`:935-949`, `status:available,origin:worker` only) is a partial backstop. Issues that are not `origin:worker`, and in-review issues still assigned to the checkpoint runner (the case #38355 fixed), have no fallback and stay undispatchable.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The reference pattern is known: a bounded paginated read plus a cursor file in the existing state dir. The worker still has to choose the stop rule and the stamp semantics and record the choice. No trust boundary changes, because every restore still goes through `_pmpc_restore_closed_checkpoint_dispatch`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge-partial-continuation.sh:797-827`: paginate the closed-PR listing in `_pmpc_reconcile_closed_checkpoints` until reaching PRs older than the floor; persist the floor.
- `EDIT: .agents/scripts/tests/test-pulse-merge-partial-continuation.sh:242-245`: let the `pulls?state=closed` fake serve per-page fixtures; add cases next to `test_closed_checkpoint_dispatch_recovery` (`:1152`).

### Complete Write Surface

- **Callers/readers:** the only caller is `_pm_reconcile_partial_continuations`, `.agents/scripts/pulse-merge-partial-continuation.sh:1020`, which ignores the return code (`|| true`).
- **Writers/mutation paths:** unchanged. Restores still go only through `_pmpc_restore_closed_checkpoint_dispatch` (`:760-795`). The new write is a per-repo stamp file under `${PULSE_PARTIAL_RECONCILE_STATE_DIR:-${HOME}/.aidevops/cache/partial-continuation}` (same dir as the traversal cursor, `:991-997`). Use a distinct filename suffix so it never collides with the cursor file `${repo_slug//\//__}`.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-merge-partial-continuation.sh` (214 checks at `0d0eb38dc4`).
- **Schemas/config:** reuse `PULSE_CLOSED_CHECKPOINT_LOOKBACK_SECONDS` (default 604800, `:807`) as the hard floor. An optional page cap env var may be added; validate it the same way as `:808`.
- **Generated/deployed mirrors:** deployed to `~/.aidevops/agents/scripts/` by `setup.sh`; nothing generated.
- **Migrations/backfills:** with no stamp yet, fall back to the lookback floor. The first scan after deploy is therefore the backfill.
- **Cleanup/rollback paths:** reverting the commit restores the single-page read. A leftover stamp file is harmless.

### Implementation Steps

1. Read the stamp, a last-complete-scan epoch. Floor = max(stamp - margin, now - lookback). The margin, for example 3600s, absorbs clock skew and in-flight writes.
2. Page through `pulls?state=closed&sort=updated&direction=desc&per_page=100&page=N`. Apply the existing jq row filter (`:811-819`) per page. Stop when the page's oldest `updated_at` < floor, the page is short, the deadline (`$2`) is reached, or a page cap is reached. Stopping on `updated_at` is safe because `updated_at >= closed_at`.
3. Advance the stamp to the scan's start epoch only when the scan reached the floor. A deadline stop, page-cap stop or unreadable page leaves the stamp unchanged, so the next scan covers the gap again. Restores are already idempotent through the per-PR marker in `_pmpc_closed_checkpoint_release` (`:706`).
4. Keep the `review:1:` traversal gate (`:806`) so resumed pages do not rescan.
5. Run `shellcheck` and the test file. Then source the script in a shell with `gh` authenticated and call `_pmpc_reconcile_closed_checkpoints marcusquinn/aidevops $(( $(date +%s) + 120 ))` against a scratch `PULSE_PARTIAL_RECONCILE_STATE_DIR`. Confirm the stamp is written and the log shows no unexpected restores.

### Hazards and Compatibility

- **Concurrency/atomicity:** two pulse hosts may scan the same repo. Each restore is already fenced by fresh reads and the per-PR marker. Write the stamp with temp-file plus `mv -f`, following `.agents/scripts/pulse-wrapper-cycle.sh:738`.
- **Migration/rollback:** with no stamp, the scan falls back to the lookback floor. On rollback the stamp is ignored.
- **Mixed-version/backward compatibility:** older hosts keep the 30-PR read. The two versions cannot conflict, because each restore is idempotent.
- **Idempotency/retry:** a partial scan never advances the stamp, so a retry rescans the window. The marker prevents double comments.
- **Partial failure/recovery:** an unreadable page returns 1 without advancing the stamp. That keeps today's `|| true` caller semantics.

### Complexity Impact

- **Target function:** `_pmpc_reconcile_closed_checkpoints` in `.agents/scripts/pulse-merge-partial-continuation.sh`
- **Current line count:** 25 lines
- **Estimated growth:** +25 to +35 lines
- **Projected post-change:** about 60 lines (60% of threshold)
- **Action required:** Watch. Extract a `_pmpc_closed_checkpoint_rows` page helper if the function passes 80 lines. The file is 1087 lines, under the 1500 limit.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-merge-partial-continuation.sh
shellcheck .agents/scripts/pulse-merge-partial-continuation.sh .agents/scripts/tests/test-pulse-merge-partial-continuation.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the test file proves pagination, the stop rules and stamp semantics. ShellCheck and changed-file lint cover style gates. The scratch-dir live call in step 5 proves the production read path.
- **Broad verification trigger:** Not required. This is a single pulse helper; no shared contracts or root tooling change.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `bash .agents/scripts/tests/test-pulse-merge-partial-continuation.sh`
- [ ] WIP commit created before broad gates: `wip: paginate closed-checkpoint scan`
- [ ] Evidence-triggered broad verification then run: not required. The change is to a single helper

### Scope Boundaries

**Hard boundaries:** do not change restore eligibility (`_pmpc_restore_closed_checkpoint_dispatch` and the helpers it calls) or the worktree-reuse fence from #38370.

**AI brief owner:** marcusquinn (maintainer)

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-merge-partial-continuation.sh`
- `.agents/scripts/tests/test-pulse-merge-partial-continuation.sh`

## Acceptance Criteria

- [ ] A test with more than one page of closed PRs, where the checkpoint PR is only on page 2 and newer than the stamp, restores `auto-dispatch` for its issue.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-partial-continuation.sh"
  ```

- [ ] Scanning stops at the first page whose oldest `updated_at` is older than the floor. A deadline stop or an unreadable page leaves the stamp unchanged, which a test asserts.
- [ ] Negative: the fixed 30-PR single-page read is gone.

  ```yaml
  verify:
    method: codebase
    pattern: "pulls\\?state=closed&sort=updated&direction=desc&per_page=30\""
    path: ".agents/scripts/pulse-merge-partial-continuation.sh"
    expect: absent
  ```

- [ ] Negative: restore eligibility is unchanged, and every existing closed-checkpoint case in `test_closed_checkpoint_dispatch_recovery` still passes.
- [ ] Changed-file lint is clean (`shellcheck`, `linters-local.sh --changed`).

## Context & Decisions

- One gap from the GH#38355 closeout turned out not to exist: framework terminal closes from `pr-checkpoint-terminal-action.sh` are also covered by the new restore. The fenced terminal claim is deleted on exit (`:224`), and the terminal record marker is not an ownership event (`pulse-merge-partial-continuation.sh:28`). This brief therefore covers only the page window.
- Ruled out: a larger fixed page (`per_page=100`). It only moves the cliff, and a long outage still overflows it.
- Ruled out: listing closed PRs by `closed_at`. The GitHub pulls list API has no `closed` sort key.

## Relevant Files

- `.agents/scripts/pulse-merge-partial-continuation.sh:797-827`: the scan to change.
- `.agents/scripts/pulse-merge-partial-continuation.sh:988-1020`: traversal caller and cursor-dir pattern.
- `.agents/scripts/pulse-wrapper-cycle.sh:730-751`: atomic stamp write pattern.
- `.agents/scripts/tests/test-pulse-merge-partial-continuation.sh:242-245,1141-1226`: the fake `gh` dispatch and existing closed-checkpoint cases.
