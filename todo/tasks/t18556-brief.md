<!-- aidevops:brief-schema=v2 -->

# t18556: Release reconcile: look up the tag-push publish run by exact head_sha and skip recovery dispatch when channels are already published

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** While finishing the maintainer-authorized v3.37.31 release, `aidevops release reconcile 33042` did not find the successful tag-push publish run and dispatched a redundant recovery publish. Read-only replays showed that GitHub's event-filtered workflow-run list intermittently returns stale pages. Following ambient-capture policy, this was filed as GH#33073 for auto-dispatch.

## What

`aidevops release reconcile` finds the tag-push `publish-packages.yml` run through an exact `head_sha` query. When no run is found but GitHub release, npm and Homebrew already verify for the tag, it reports `WORKFLOW_LOOKUP=uncorroborated`, returns 8 (pending) and dispatches nothing. A genuinely missing publication, where channels do not verify, still dispatches exactly one recovery.

## Why

- `_full_loop_release_find_workflow_run` (`.agents/scripts/full-loop-release-reconcile.sh:599-666`) lists every push run with `-f event=push -F per_page=100 --paginate` (L616-617). It then selects `head_branch == tag and head_sha == tag_commit` in jq (L633).
- `_full_loop_release_inspect_remote` (L950-997) turns an empty selection into rc 3. `_full_loop_release_reconcile` then dispatches recovery (L1577-1580), without checking whether the channels are already published.
- Evidence from 2026-09-29:
  - push run `36617731862` (`push`, `v3.37.31`, `8fe6334e…`, `success`) was created at 19:13:43Z, yet reconcile dispatched recovery run `36618899675` at 19:23:29Z;
  - release, npm and Homebrew were already at 3.37.31, so the recovery run was redundant; it succeeded idempotently;
  - a read-only replay of L616-617 returned a single page of 22 push runs, none for `v3.37.31`;
  - one native `gh` 2.101.0 repeat returned `total_count:140`, newest 2026-09-16, while the URL form returned 249 with `v3.37.31` first; later repeats returned 249;
  - `-f event=push -f head_sha=8fe6334e…` on the workflow endpoint returned exactly `total_count:1`.
- A stale list must not cause a publish side effect. An exact query shrinks the response from about 249 runs to 1, and checking the channels before dispatch removes the remaining false positive.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: two small, targeted edits in one release script (one query argument, and one guarded branch before an existing return), plus stub-driven scenarios in existing harnesses. Not `tier:simple`: the test stub must require the new argument, or the existing PASS lines would pass vacuously, and the dispatch decision is a release side-effect boundary.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/full-loop-release-reconcile.sh:616-617,960-964`:
  - Add `-f head_sha="$tag_commit"` to the push-event query. Model it on the `head_sha` run query at `.agents/scripts/postflight-check.sh:144-145`. Leave the `workflow_dispatch` query (L618-619) unchanged, because recovery runs execute on a `main` commit and are correlated by display title (L634-638).
  - In `_full_loop_release_inspect_remote`, when `find_rc` is 3:
    - call `_full_loop_release_verify_channels "$repo" "$tag_name"` (L890). It reads release, npm and Homebrew state and does not use `_FULL_LOOP_RELEASE_RUN_JSON`;
    - if it verifies, print `RELEASE_TAG=`, `WORKFLOW_STATUS=absent` and `WORKFLOW_LOOKUP=uncorroborated`, then return 8;
    - otherwise keep today's output and return 3.
- `EDIT: .agents/scripts/tests/test-full-loop-release-reconcile-channels.sh:49-53`: in the `gh` stub's push branch, return run `10` only when `$args` contains ` -f head_sha=3333333333333333333333333333333333333333 `, and `{"workflow_runs":[]}` otherwise. Keep the `oversized` mode (L28-43) working.
- `EDIT: .agents/scripts/tests/test-full-loop-release-reconcile.sh:26-65`: add two scenarios to the inline boundary subshell. Model them on the existing grace scenarios at L44-59, which override `_full_loop_release_find_workflow_run` and `_full_loop_release_verify_channels` and count dispatches in `grace-dispatch.log`.

### Complete Write Surface

- **Callers/readers:**
  - `_full_loop_release_find_workflow_run` is called from `_full_loop_release_verify_stale_publication_run` (L738), `_full_loop_release_inspect_remote` (L960, L975) and the supersession path (L1315).
  - The new push filter narrows every call to the exact tag commit, which all of them already require through the jq selection.
  - `_full_loop_release_inspect_remote` is called by `_full_loop_release_reconcile` (L1554) for the `status` and `reconcile` modes of `aidevops release`.
  - The standard-tier release child and operators read its stdout markers (`.agents/workflows/release.md`).
- **Writers/mutation paths:** the only side effect is `_full_loop_release_dispatch_recovery` (L999-1019), which is now skipped when channels already verify. No lane or receipt writes change.
- **Schemas/config:** adds one stdout marker, `WORKFLOW_LOOKUP=uncorroborated`. There are no new env vars or files.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/full-loop-release-reconcile.sh` to `~/.aidevops/agents/scripts/`, and the `aidevops release` CLI runs the deployed copy.
- **Migrations/backfills:** N/A because there is no persisted state or format change.
- **Cleanup/rollback paths:** revert the PR touching `.agents/scripts/full-loop-release-reconcile.sh` and its two test files. Reconcile then returns to the full-history scan and dispatches on absence, as it does today.
- **Existing verification/tests:** `.agents/scripts/tests/test-full-loop-release-reconcile.sh`, which sources the `-proof`, `-discovery`, `-runtime`, `-channels`, `-supersession` and `-command` suites.

### Implementation Steps

1. Add `-f head_sha="$tag_commit"` to the L616-617 push query, after `-f event=push`.
2. Replace the L961-964 absent block with the channel-corroborated branch described above. Keep explicit returns, and put any new variable in the function's existing `local` declarations.
3. Update the channels-test `gh` stub push branch so that it requires the exact `head_sha` argument.
4. Add the two inline scenarios, both with `_full_loop_release_find_workflow_run` returning 3:
   - `_full_loop_release_verify_channels` returns 0: expect rc 8, `WORKFLOW_LOOKUP=uncorroborated` in the output, and an unchanged dispatch count;
   - it returns 1: expect rc 3.
5. Run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** reconcile holds the release lane. The change only removes a dispatch in one case and adds no writes.
- **Migration/rollback:** there is no persisted state, so rollback is a revert.
- **Mixed-version/backward compatibility:** older CLI copies keep dispatching on absence. The `workflow_dispatch` correlation and `display_title` contract are unchanged, so either version still recognises recovery runs created by the other.
- **Idempotency/retry:** an `uncorroborated` result returns 8, so a later reconcile retries the exact lookup and reaches `published` once the run is visible. There is no dispatch loop, because rc 8 never dispatches.
- **Partial failure/recovery:**
  - If channel verification fails because of a transient API error, the helper returns 3 and dispatches as it does today, which is the existing fail-safe path.
  - If the run was genuinely deleted while channels verify, reconcile stays pending with `WORKFLOW_LOOKUP=uncorroborated` for operator review instead of republishing.

### Complexity Impact

- **Target function:** `_full_loop_release_inspect_remote` in `.agents/scripts/full-loop-release-reconcile.sh`
- **Current line count:** 48 lines (L950-997; threshold: 100 lines for function-complexity)
- **Estimated growth:** about +6 lines
- **Projected post-change:** about 54 lines (54% of threshold). `_full_loop_release_find_workflow_run` grows by 1 line, to about 69.
- **Action required:** none.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/full-loop-release-reconcile.sh .agents/scripts/tests/test-full-loop-release-reconcile.sh .agents/scripts/tests/test-full-loop-release-reconcile-channels.sh
bash .agents/scripts/tests/test-full-loop-release-reconcile.sh
```

- **Surface mapping:**
  - `shellcheck` covers all three changed scripts.
  - `test-full-loop-release-reconcile.sh` runs:
    - the new inline scenarios, covering the dispatch-skip decision and the fail-safe rc 3 path (the partial-failure hazard);
    - the channels suite with the stricter stub, proving the exact `head_sha` query is sent and that correlation, mismatched-ref rejection, oversized pagination and schema fail-closed still hold (the mixed-version hazard);
    - the grace-window, supersession and command suites, proving the `status`/`reconcile` flows are unchanged (the idempotency hazard).
- **Broad verification trigger:** Not required. There are no shared config, root tooling, dependency graph or `.github/workflows/` changes.

### Scope Boundaries

**Hard boundaries:**

- Do not change `.github/workflows/publish-packages.yml`, the recovery `display_title` format, or `_full_loop_release_dispatch_recovery`.
- Do not change the success grace window (`_full_loop_release_success_grace_expired`) or channel-verification logic.
- Do not add retries or sleeps around the run-list API.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/full-loop-release-reconcile.sh`
- `.agents/scripts/tests/test-full-loop-release-reconcile.sh`
- `.agents/scripts/tests/test-full-loop-release-reconcile-channels.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] The push-run lookup sends `-f head_sha=<tag_commit>` and still requires `head_branch == <tag>`.

  ```yaml
  verify:
    method: codebase
    pattern: "head_sha=\"\\$tag_commit\""
    path: ".agents/scripts/full-loop-release-reconcile.sh"
  ```

- [ ] If no run is found but channels verify, reconcile returns 8 with `WORKFLOW_LOOKUP=uncorroborated` and dispatches nothing.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-release-reconcile.sh"
  ```

- [ ] Negative/regression:
  - if no run is found and channels do not verify, reconcile returns 3 and dispatches exactly one recovery;
  - recovery correlation, mismatched-ref rejection, oversized pagination, schema fail-closed and grace-window tests pass unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-release-reconcile.sh"
  ```

- [ ] Changed-file lint is clean: `shellcheck .agents/scripts/full-loop-release-reconcile.sh .agents/scripts/tests/test-full-loop-release-reconcile.sh .agents/scripts/tests/test-full-loop-release-reconcile-channels.sh`

## Context & Decisions

- The fix uses the exact `head_sha` query plus a channel check, rather than a retry. The exact query removes pagination and most of the stale-page exposure, and the channel check guards the side effect even if the exact query is also served stale. A retry would add latency and still depend on the list endpoint.
- The helper returns 8 (pending) instead of 0 when the run is missing but channels verify. Terminal `published` still requires the correlated workflow evidence that the provenance contract relies on.
- `head_sha` is not added to the recovery query, because recovery runs execute on `main` and a tag-commit filter would hide them.

## Relevant Files

- `.agents/scripts/full-loop-release-reconcile.sh:599-666,890-997,999-1019,1554-1583` — run finder, channel verify, inspect, dispatch, reconcile switch
- `.agents/scripts/postflight-check.sh:144-145` — reference `head_sha` run query
- `.agents/scripts/tests/test-full-loop-release-reconcile.sh:26-65` — inline boundary scenarios
- `.agents/scripts/tests/test-full-loop-release-reconcile-channels.sh:6-69,179-273` — `gh` stub and finder assertions
