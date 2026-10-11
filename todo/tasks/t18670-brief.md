<!-- aidevops:brief-schema=v2 -->

# fix(dispatch-dedup): an open PR with over 100 changed files must not make the open-siblings lookup permanently uncertain

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `dispatch dedup open_siblings PR_LOOKUP_UNCERTAIN files hasNextPage oversized PR` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open or recently merged related PR. Related history: GH#32000 (same failure class for the open-commits lookup, fixed by paginating commits), t18131 / `fca5c68796` (moved this lookup from `gh pr list --json ...,files,labels` to response-metered GraphQL and added the `hasNextPage` checks)
- [x] File refs verified at origin/main ae02c03740: `_ddpr_graphql_open_siblings` (`.agents/scripts/dispatch-dedup-pr.sh:258`), its validation (`:301-309`), the only caller `_has_open_pr_check_healthy_sibling` (`:484`, call at `:490`) and its `complete_planning_only_scope` (`:544-548`)
- [x] Tier: `tier:standard` — one lookup validator and one jq predicate in one dispatch-dedup module; no claim or trust gate weakened
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation. A high-priority issue in a managed private repo was rejected on every dispatch attempt with `PR_LOOKUP_UNCERTAIN: open_siblings lookup failed ... (reason=response_validation_failed)`.

## What

The open-siblings lookup accepts a sibling PR whose file list is longer than one page. It reports the partial page as `filesTruncated` instead of failing the whole response. A truncated PR is never exempt as planning-only, so it can still own the issue. Partial label pages still fail the lookup.

## Why

- `_ddpr_graphql_open_siblings` searches `repo:<slug> is:pr is:open #<issue>` and requests `files(first: 100)`. Its validator requires `files.pageInfo.hasNextPage == false` for every result, so one result with more than 100 changed files fails the lookup. `_has_open_pr_check_healthy_sibling` then fails closed with `PR_LOOKUP_UNCERTAIN`, which blocks dispatch.
- GitHub search matches an issue number anywhere in a PR, including its comments. One large open PR therefore blocks every issue it mentions, on every cycle, even when its title and body do not reference that issue.
- Observed on this runner: the pulse log has 18 `open_siblings lookup failed ... (reason=response_validation_failed)` records, all for one `priority:high` `auto-dispatch` issue in a managed private repo, and 20 rejected dispatch attempts for it (`dispatch_with_dedup returned rc=1`) that took 14.7–65.8 s each, about 11.5 min in total. Its only search match is an open PR with 595 changed files and `CHANGES_REQUESTED`, whose title and body reference other issues only.
- The file list has one consumer: `complete_planning_only_scope`, which exempts a PR whose changed files are all `TODO.md` or `todo/**`. It already requires the returned file count to equal `changedFiles`, so a partial page could only ever keep a PR owning. Failing the lookup on it added no safety.
- Before t18131 the lookup used `gh pr list --json ...,files,labels` with no truncation check; the strict check arrived with the move to response-metered GraphQL.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** a decided fail-closed policy inside one module with a verified reference pattern and focused tests; `dispatch-dedup-pr.sh` is not listed in `.agents/configs/self-hosting-files.conf`, so no dispatch-path override applies.

## How

### Files to Modify

- `EDIT: .agents/scripts/dispatch-dedup-pr.sh:258-325` — `_ddpr_graphql_open_siblings`: validate `files.pageInfo.hasNextPage` as a boolean instead of requiring `false`, and emit it per PR as `filesTruncated`. Keep `labels.pageInfo.hasNextPage == false`.
- `EDIT: .agents/scripts/dispatch-dedup-pr.sh:544-548` — `complete_planning_only_scope`: also require `filesTruncated` to be false, so a truncated PR is never exempt even if `changedFiles` disagrees with the page.
- `EDIT: .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh` — the partial-connections test keeps its labels case; three new tests: a draft sibling with partial files blocks as a checkpoint, an oversized sibling that does not reference the issue no longer blocks it, and a truncated sibling whose first page looks planning-only still owns the issue.

### Complete Write Surface

- **Callers/readers:** `_has_open_pr_check_healthy_sibling` in `.agents/scripts/dispatch-dedup-pr.sh` is the only caller (`rg -n _ddpr_graphql_open_siblings .agents/` finds the definition and one call). Its draft-checkpoint match reads title, body, labels and `isDraft`; its healthy-sibling match reads review/merge state, title, body and `complete_planning_only_scope`.
- **Writers/mutation paths:** N/A because the lookup is a read-only GraphQL search; `has-open-pr` writes nothing on GitHub or local state.
- **Existing verification/tests:** `.agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh` encodes the lookup contract through `dispatch-dedup-helper.sh has-open-pr`; the production path is the same command and the pulse log `PR_LOOKUP_RESULT=uncertain ... scope=open_siblings` records.
- **Schemas/config:** N/A because the new `filesTruncated` key exists only in the in-memory JSON passed from `_ddpr_graphql_open_siblings` to its caller; no config, cache or serialized format changes.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/dispatch-dedup-pr.sh` to `~/.aidevops/agents/scripts/` on release/update; no generated copies.
- **Migrations/backfills:** N/A because no stored data or cache depends on the response shape; the next pulse cycle uses the new lookup.
- **Cleanup/rollback paths:** N/A because nothing is persisted; reverting `.agents/scripts/dispatch-dedup-pr.sh` restores the strict check.

### Implementation Steps

1. In `_ddpr_graphql_open_siblings`, replace `.files.pageInfo.hasNextPage == false` with `(.files.pageInfo.hasNextPage | type) == $boolean_type`, keep the labels check, and add `filesTruncated: .files.pageInfo.hasNextPage` to the emitted object. Document the reasoning in the function header.
2. In `complete_planning_only_scope`, add `((.filesTruncated // false) | not) and` before the existing count checks. Keep it parenthesised: jq `|` binds looser than `and`.
3. In the test file, reduce the partial-connections test to its labels case and add the three tests named above to `main`, modelled on `test_has_open_pr_allows_when_no_healthy_sibling`.
4. Run ShellCheck and the suite on Bash 5 and `/bin/bash` 3.2, then the negative controls and the production-path check below.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because the change is a pure transformation of one API response inside one process; no locks, claims or shared files are touched.
- **Migration/rollback:** none needed; nothing persists the response, so deploy and rollback take effect on the next pulse cycle.
- **Mixed-version/backward compatibility:** producer and only consumer ship in the same file, so they cannot be mixed; older runners keep failing closed on oversized siblings until they update.
- **Idempotency/retry:** the lookup is read-only and repeatable; a retry returns the same decision for the same PR state.
- **Partial failure/recovery:** API errors, missing cost and partial labels still fail closed with `PR_LOOKUP_UNCERTAIN`; only a partial file page is now decided.
- **Planning-only exemption:** only complete file lists can exempt a sibling, as before; the new `filesTruncated` guard also covers a `changedFiles` count that disagrees with the page.

### Complexity Impact

- **Target function:** `_has_open_pr_check_healthy_sibling` in `.agents/scripts/dispatch-dedup-pr.sh`
- **Current line count:** 86 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +1 line
- **Projected post-change:** 87 lines (87% of threshold)
- **Action required:** Watch — the function was already in the warning band; `_ddpr_graphql_open_siblings` grows 68→69 lines.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/dispatch-dedup-pr.sh .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh
bash .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh
/bin/bash .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh
.agents/scripts/dispatch-dedup-helper.sh has-open-pr <issue> <owner/repo> "<issue title>"
```

- **Surface mapping:** ShellCheck covers both edited scripts. The suite on Bash 5 and 3.2 proves all four acceptance criteria and the Bash 3.2 compatibility of the jq change. The production-path command proves the first criterion against the live oversized PR.
- **Negative controls:** the new test file run against origin/main fails exactly the three new tests, each with `PR_LOOKUP_UNCERTAIN ... response_validation_failed`. Run against the fix without the `filesTruncated` guard, only the truncated planning-looking test fails.
- **Production path:** for the blocked issue, the deployed v3.39.14 helper prints `PR_LOOKUP_UNCERTAIN`; the patched helper exits non-zero with no output (no open-PR evidence).
- **Runtime:** after deploy, the pulse log should stop recording `reason=response_validation_failed scope=open_siblings` for that issue, which then proceeds through the remaining dispatch layers.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Recoverability Checkpoint

- [x] Focused functional verification passes: `bash .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh` (60/60 on Bash 5 and 3.2)
- [ ] WIP commit created before broad gates: `wip: t18670 decide open siblings with partial file pages`
- [ ] Evidence-triggered broad verification then run: not required — single module, no shared contract

### Scope Boundaries

Initial implementation map. Directly necessary adjacent integration follows
`reference/worker-discipline.md` "Integration scope recovery".

**Hard boundaries:** do not relax the partial-labels, cost or API-error fail-closed paths; do not paginate files.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request
and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/dispatch-dedup-pr.sh`
- `.agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh`
- `TODO.md`
- `todo/tasks/t18670-brief.md`

## Acceptance Criteria

- [ ] A sibling PR with more than 100 changed files no longer makes the open-siblings lookup uncertain.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh"
  ```

- [ ] A truncated sibling PR is never exempt as planning-only.

  ```yaml
  verify:
    method: codebase
    pattern: "filesTruncated // false\\) \\| not"
    path: ".agents/scripts/dispatch-dedup-pr.sh"
  ```

- [ ] Partial label pages still fail the lookup (regression guarantee).

  ```yaml
  verify:
    method: codebase
    pattern: "labels.pageInfo.hasNextPage == false"
    path: ".agents/scripts/dispatch-dedup-pr.sh"
  ```

- [ ] ShellCheck and the has-open-pr suite on Bash 5 and 3.2 pass.

## Context & Decisions

- **Mark truncation instead of paginating files:** GH#32000 paginated commits because commit headlines decide ownership. File paths here only grant the planning-only exemption, and a large PR is never planning-only, so extra pages would cost GraphQL quota and change no decision.
- **Keep labels strict:** partial labels could classify a protected draft as worker-owned and route it to continuation.
- **Not in scope:** narrowing the search to title/body matches, and the 20-result search bound.

## Relevant Files

- `.agents/scripts/dispatch-dedup-pr.sh:258` — `_ddpr_graphql_open_siblings`, the lookup and its validator
- `.agents/scripts/dispatch-dedup-pr.sh:484` — `_has_open_pr_check_healthy_sibling`, the only caller
- `.agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh` — fixture-driven suite for `has-open-pr`

## Dependencies

- **Blocked by:** none
- **Blocks:** dispatch of issues that GitHub search links to an open PR with more than 100 changed files
- **External:** none
