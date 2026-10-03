<!-- aidevops:brief-schema=v2 -->

# t18545: Pulse merge: retry transient author permission lookups and stop manual-merge comments for them

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Found while monitoring pulse cycle `20260929T052653Z-87280` on aidevops 3.37.30. Clean worker PRs by the repository owner were skipped, and one received a "merge manually" comment. Issue: GH#33000.

## What

Stop transient collaborator-permission lookup failures from:

1. blocking every PR by the same author for the rest of a merge pass;
2. posting a PR comment telling a maintainer to merge manually.

The merge gate stays fail-closed: an unresolved lookup still skips that PR's merge for the current pass.

## Why

- At 05:35Z on 2026-09-29, worker PRs #32991 (GH#32762, `CLEAN`) and #32990 (GH#32761) were both skipped. Each logged `permission check failed for author marcusquinn (HTTP unknown)`, and #32991 got the permission-failure comment. The author owns the repository, so this was a read/transport failure, not a denial.
- The second skip came from the per-pass negative cache. `_pulse_author_permission_lookup` writes a failed `rc=2` to `AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR` (`.agents/scripts/pulse-merge-author-checks.sh:163-167`; the cache is created per repo pass in `.agents/scripts/pulse-merge-process.sh:733-735`). Every later lookup for that author in the same pass then fails without retrying.
- The comment text (`.agents/scripts/pulse-merge-gates.sh:621`) says **"A maintainer must review and merge this PR manually."** In fact the pulse retries on its next pass.
  - PRs #32919 and #32925 got the same comment earlier that day (logged `HTTP 200`), and collaborators then merged them by hand. That is human attention spent on a condition the automation would have cleared.
  - The comment is posted once per PR, ever (`grep -qF 'Permission check failed'` at L614), so the stale instruction stays after the lookup recovers.
- The skip log (`.agents/scripts/pulse-merge.sh:486`) records only the HTTP status, not `AIDEVOPS_GH_COLLAB_PERMISSION_REASON`. `HTTP unknown` and `HTTP 200` failures cannot be told apart from the log.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: three coordinated edits in the pulse merge path plus focused test extensions. Not `tier:simple`, because it touches a `#aidevops:trust-boundary` gate where a lookup failure must never become a collaborator verdict.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge-author-checks.sh:130-182` — `_pulse_author_permission_lookup`:
  - Keep caching `rc=0` verdicts for the whole pass.
  - On a cached failure, allow exactly one fresh uncached retry per `repo|author` per pass, then serve the cached failure.
  - Add a fifth cache line holding the reason, and restore it on cached reads.
- `EDIT: .agents/scripts/pulse-merge-author-checks.sh:66-75` — `_pulse_author_permission_state_set` and the module globals near L58: add a `_PULSE_AUTHOR_PERMISSION_REASON` global, set from `AIDEVOPS_GH_COLLAB_PERMISSION_REASON` in `_pulse_author_permission_lookup_uncached` (L94-128).
- `EDIT: .agents/scripts/pulse-merge-gates.sh:576-625` — `check_permission_failure_pr`:
  - Accept an optional reason argument.
  - For transient classes, log only and post no comment. Transient means HTTP `unknown`, `429` or `5xx`, or a reason containing `api-failure`.
  - Non-transient classes still post one comment, reworded to say the pulse retries automatically on every merge pass and that a maintainer acts only if the PR stays unmerged.
- `EDIT: .agents/scripts/pulse-merge.sh:484-487` — pass `${_PULSE_AUTHOR_PERMISSION_REASON:-unknown}` to `check_permission_failure_pr` and include `reason=` in the skip log line.
- `EDIT: .agents/scripts/shared-gh-collaborator-permission.sh:256-324` — check whether `api_response=$(... 2>&1)` (L256) lets stderr diagnostics that start with `[` (e.g. `[gh-cooldown] ...`) enter the parsed body and turn a `200` into `malformed-response` (L324). If confirmed, keep stderr out of the parsed body. If not reproducible, record the evidence in the PR body.
- `EDIT: .agents/scripts/tests/test-pulse-merge-gates-role-guard.sh:100` — add cases for:
  - transient failure then success in the same pass;
  - two failures served from cache;
  - transient failures posting no comment;
  - non-transient failures posting one reworded comment.

  Stub `_gh_collaborator_permission_lookup` as in `.agents/scripts/tests/test-pulse-wrapper-characterization.sh:794`.

### Complete Write Surface

- **Callers/readers:** `_is_collaborator_author` (L184) and `_is_owner_or_member_author` (L203) in `.agents/scripts/pulse-merge-author-checks.sh`; the merge-pass permission branch in `.agents/scripts/pulse-merge.sh:470-489`; `approve_collaborator_pr` in `.agents/scripts/pulse-merge-gates.sh:641,796`, which reads `_PULSE_AUTHOR_PERMISSION_HTTP` for logs only.
- **Writers/mutation paths:** `_pulse_author_permission_lookup` writes the per-pass cache file under `AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR`; `check_permission_failure_pr` writes one PR comment via `gh pr comment`; `_pulse_author_permission_state_set` writes the module globals.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-merge-gates-role-guard.sh`, `.agents/scripts/tests/test-pulse-merge-issue-sync-authority.sh`, `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh`, `.agents/scripts/tests/test-shared-gh-collaborator-permission-current-user.sh` and `.agents/scripts/tests/test-pulse-wrapper-characterization.sh`. Production evidence: `permission check failed for author` lines in `~/.aidevops/logs/pulse.log`.
- **Schemas/config:** the per-pass cache file format (4 lines: rc, state, http, value) gains a 5th reason line. Readers must tolerate a missing 5th line, and the existing `read -r ... || default` pattern already does. There is no persisted config.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`, and the pulse picks it up through the runtime bundle after release. No generated artefacts.
- **Migrations/backfills:** N/A because the cache is a `mktemp -d` directory created and removed within one repo merge pass (`.agents/scripts/pulse-merge-process.sh:733-780`), so no old-format cache survives an upgrade. Existing stale PR comments are left as they are.
- **Cleanup/rollback paths:** revert the PR. The cache dir cleanup at `.agents/scripts/pulse-merge-process.sh:744,780` is unchanged.

### Implementation Steps

1. Add the `_PULSE_AUTHOR_PERMISSION_REASON` global, set in `_pulse_author_permission_state_set`, and populate it from `AIDEVOPS_GH_COLLAB_PERMISSION_REASON` in the uncached lookup.
2. Extend the cache record with the reason line, and add a retry marker, e.g. a sibling `${cache_file}.retried` file or an attempt count line. On a cached failure without the marker, set the marker and do one uncached lookup; with the marker, return the cached failure. That is at most 2 API calls per author per pass.
3. Add a small `_pulse_permission_failure_is_transient <http> <reason>` helper in `.agents/scripts/pulse-merge-gates.sh`. Use it in `check_permission_failure_pr` to choose between log-only and comment, and reword the comment.
4. Pass the reason from `.agents/scripts/pulse-merge.sh:485`, and add `reason=` to the L486 log line.
5. Investigate the stderr capture in `.agents/scripts/shared-gh-collaborator-permission.sh:256`. Fix it only if it can be reproduced; do not change the 404 → `none` mapping or the App → gh fallback order.
6. Extend the role-guard test, then run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** the cache dir is private to one merge pass in one pulse process, and PRs are handled sequentially within a pass. Write the cache file with a single `printf ... >"$cache_file"`, as today; the retry marker must be created before the retry lookup so a crash cannot allow unbounded retries.
- **Migration/rollback:** no persisted state; roll back with a plain revert. Comments already posted are not edited or removed.
- **Mixed-version/backward compatibility:** cache readers must default the reason when the 5th line is absent. `check_permission_failure_pr` must keep working with the current 4 positional arguments, so the reason is an optional 5th argument. `_PULSE_AUTHOR_PERMISSION_HTTP` consumers at `.agents/scripts/pulse-merge-gates.sh:641,796` keep their meaning.
- **Idempotency/retry:** comment posting stays idempotent per PR (the `grep -qF 'Permission check failed'` guard). The retry is bounded to one extra uncached lookup per `repo|author` per pass.
- **Partial failure/recovery:** trust boundary (`#aidevops:trust-boundary`): a failed or unresolved lookup must still return 2 and skip the merge, and must never map to a collaborator verdict. A confirmed `read`/`triage`/`none` verdict still blocks, as today. The next pulse pass retries naturally.

### Complexity Impact

- **Target function:** `_pulse_author_permission_lookup` in `.agents/scripts/pulse-merge-author-checks.sh`
- **Current line count:** 53 lines (L130-182; threshold: 100 lines for function-complexity)
- **Estimated growth:** +15 lines (retry marker, reason line)
- **Projected post-change:** 68 lines (68% of threshold); `check_permission_failure_pr` (36 lines, L590-625) grows by about 10.
- **Action required:** none beyond extracting `_pulse_permission_failure_is_transient` as a separate helper.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-merge-author-checks.sh .agents/scripts/pulse-merge-gates.sh .agents/scripts/pulse-merge.sh .agents/scripts/shared-gh-collaborator-permission.sh
bash .agents/scripts/tests/test-pulse-merge-gates-role-guard.sh
bash .agents/scripts/tests/test-pulse-merge-issue-sync-authority.sh
bash .agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh
bash .agents/scripts/tests/test-shared-gh-collaborator-permission-current-user.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
```

- **Surface mapping:** `shellcheck` covers all four modified scripts. `test-pulse-merge-gates-role-guard.sh` proves the retry bound, transient no-comment behaviour and reworded comment for `_pulse_author_permission_lookup` and `check_permission_failure_pr` (idempotency and partial-failure hazards). `test-pulse-merge-issue-sync-authority.sh` and `test-pulse-merge-approve-collaborator-guard.sh` prove that callers in `.agents/scripts/pulse-merge.sh` and `approve_collaborator_pr` still fail closed (trust-boundary hazard). `test-shared-gh-collaborator-permission-current-user.sh` proves the lookup and reason contract in `.agents/scripts/shared-gh-collaborator-permission.sh` (mixed-version hazard). `test-pulse-wrapper-characterization.sh` proves pulse-wide sourcing and stubs still load.
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:** never approve or merge without a confirmed `admin|maintain|write` permission. Do not change the 404 → `none` mapping, the App → gh fallback order, or `_pulse_repo_allows_pr_gate_writes`. Do not edit or delete comments already posted.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-merge-author-checks.sh`
- `.agents/scripts/pulse-merge-gates.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/shared-gh-collaborator-permission.sh`
- `.agents/scripts/tests/test-pulse-merge-gates-role-guard.sh`
- `.agents/scripts/tests/test-pulse-merge-issue-sync-authority.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] One transient lookup failure followed by a success for the same author in the same pass lets that author's later PRs proceed through the merge gate.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-gates-role-guard.sh"
  ```

- [ ] Two consecutive failures for the same author in one pass are then served from cache (at most 2 API calls per author per pass).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-gates-role-guard.sh"
  ```

- [ ] Transient-class failures post no PR comment. The merge is still skipped, and the skip log line includes HTTP status and `reason=`.

  ```yaml
  verify:
    method: codebase
    pattern: "reason="
    path: ".agents/scripts/pulse-merge.sh"
  ```

- [ ] Negative/regression: a lookup failure never results in approval or merge, and a confirmed `read`/`triage`/`none` verdict still blocks as before.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh && bash .agents/scripts/tests/test-pulse-merge-issue-sync-authority.sh"
  ```

- [ ] Non-transient failures still post exactly one comment, and its wording does not tell maintainers to merge manually as the default action.

  ```yaml
  verify:
    method: codebase
    pattern: "retries automatically"
    path: ".agents/scripts/pulse-merge-gates.sh"
  ```

- [ ] After release, `permission check failed for author` lines in `~/.aidevops/logs/pulse.log` include a reason, and no new "merge this PR manually" comments appear on owner-authored worker PRs. This is observed after deploy, not in this PR.

## Context & Decisions

- A bounded retry (one extra call) was chosen over removing negative caching entirely. It keeps the API-budget protection that the per-pass cache provides, while absorbing single transient failures.
- The PR comment is kept for non-transient classes (`401`, `403`, `200` + `malformed-response`), because those may need a human. Transient classes self-clear on the next pass.

## Relevant Files

- `.agents/scripts/pulse-merge-author-checks.sh:58-182` — permission state globals, cache and lookup
- `.agents/scripts/pulse-merge-gates.sh:576-625` — `check_permission_failure_pr`
- `.agents/scripts/pulse-merge.sh:470-489` — merge-pass permission branch
- `.agents/scripts/pulse-merge-process.sh:733-780` — per-pass cache dir lifecycle (read-only for this task)
- `.agents/scripts/shared-gh-collaborator-permission.sh:229-377` — lookup and failure resolution
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh:794` — lookup stub pattern
