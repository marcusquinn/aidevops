<!-- aidevops:brief-schema=v2 -->

# fix(project-config): stop re-filing the .aidevops.json migration issue from a stale local index and an unmatched duplicate search

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `project-config migration .aidevops.json tracked issue re-filed loop` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open or recently merged related PR on `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh`
- [x] File refs verified at origin/main 277aae978b: `_project_config_migration_exists` (`.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh:80`), `_project_config_queue_migration` (`:106`) and its three callers (`aidevops-update-lib.sh:166`, `aidevops-init-lib.sh:1084`, `repo-aidevops-health-helper.sh:429`)
- [x] Tier: `tier:standard` — two read-only gates in one library function chain, with focused test updates
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation. Workers in a managed private repo kept being dispatched to the same `chore: stop tracking local .aidevops.json` issue, which each closed without a PR.

## What

`aidevops update`, `aidevops init` and the scheduled repo health keeper file at most one open migration issue per repository. They file only while the default branch still tracks `.aidevops.json`, and an unknown GitHub answer never files.

## Why

- `_project_config_migration_exists` searches `<!-- aidevops:project-config-migration --> in:body`. GitHub search never matches that unquoted HTML-comment marker; the quoted phrase does. Measured on one repository with an open marker issue: the unquoted query returns no result, the quoted query returns the issue. The duplicate check therefore always reported "none", and every update and health run filed another issue (up to the 3-repo queue limit per run).
- The trigger is `_project_config_is_tracked`, which reads the local index. A canonical checkout that is behind its remote still tracks the file after the default branch has migrated, so the issue was re-filed indefinitely for an already-migrated repository. The health keeper reaches this path on every scheduled run; `aidevops update` reaches it on every release.
- A failed duplicate lookup returned 1 ("none"), so an API error also filed.
- Observed on this runner: one managed private repo has 44 of these issues since 2026-09-27; its default branch no longer tracks the file (contents API HTTP 404) while its canonical checkout is 14 commits behind. Workers were dispatched to them and closed them without a PR. Two other repos accumulated 18 and 17 open duplicates; their default branches still track the file. Other installations' public repos show the same pattern.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** a decided fail-closed policy in one library with a verified reference pattern (`quality-feedback-helper.sh` `_fetch_file_on_branch` HTTP 404 handling) and focused tests; the library is not listed in `.agents/configs/self-hosting-files.conf`.

## How

### Files to Modify

- `EDIT: .agents/scripts/aidevops-cli/aidevops-project-config-lib.sh:49-93` — quote the marker as a search phrase (`_PROJECT_CONFIG_MIGRATION_QUERY`); make `_project_config_migration_exists` return 2 on lookup failure; add `_project_config_remote_tracks_config` (contents API on the default branch: 0 tracked, 1 HTTP 404, 2 unknown) and `_project_config_migration_needed`, which declines on a migrated default branch, an existing issue/PR, or any unknown answer.
- `EDIT: .agents/scripts/aidevops-cli/aidevops-project-config-lib.sh:118-121` — `_project_config_queue_migration` calls `_project_config_migration_needed` in place of the old existence check.
- `EDIT: .agents/scripts/tests/test-update-project-config-safety.sh` — stub the remote check, make later runs simulate a new release (they previously skipped the tracked repo, so the duplicate assertion never reached the migration path), and add stale-index, lookup-failure and re-queue cases.

### Complete Write Surface

- **Callers/readers:** `_project_config_write_migration_plan` → `_project_config_queue_migration` is called from `aidevops-update-lib.sh:166` (`_update_sync_projects`), `aidevops-init-lib.sh:1084` (canonical init of a tracked config) and `repo-aidevops-health-helper.sh:429` (`_sync_single_repo_config`). `rg -n "_project_config_migration_exists|_project_config_queue_migration" .agents/` finds no other callers.
- **Writers/mutation paths:** the only write is `_project_config_write_migration_issue` (`gh-write-helper.sh issue create`), now reached only after both new gates pass. No local files change.
- **Existing verification/tests:** `.agents/scripts/tests/test-update-project-config-safety.sh` (update path) and `.agents/scripts/tests/test-repo-aidevops-health.sh` (health path; its tracked fixture has no origin, so it stops before these gates).
- **Schemas/config:** N/A because no config key, cache or serialized format changes; `AIDEVOPS_PROJECT_CONFIG_MIGRATION_MAX_REPOS` keeps its meaning.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/aidevops-cli/` to `~/.aidevops/agents/scripts/aidevops-cli/` on release/update; no generated copies.
- **Migrations/backfills:** N/A because no stored data or cache changes; existing duplicate issues are closed separately by the maintainer session, and the fix only stops new ones.
- **Cleanup/rollback paths:** N/A because nothing is persisted; reverting the library restores the old behaviour.

### Implementation Steps

1. Add `_PROJECT_CONFIG_MIGRATION_QUERY="\"${_PROJECT_CONFIG_MIGRATION_MARKER}\" in:body"` and use it for both the issue and PR searches.
2. Return 2 from `_project_config_migration_exists` when `gh issue list` or `gh pr list` fails.
3. Add `_project_config_remote_tracks_config` using `gh api --silent "repos/<slug>/contents/.aidevops.json"`; only `HTTP 404` means absent. It runs after the write-permission check, so a 404 cannot mean an inaccessible repository.
4. Add `_project_config_migration_needed` and call it from `_project_config_queue_migration`.
5. Update the test as described, then run it on Bash 5 and `/bin/bash` 3.2, ShellCheck, `linters-local.sh --changed`, the negative control and the live read-only checks below.

### Hazards and Compatibility

- **Concurrency/atomicity:** unchanged; two concurrent runs can still both pass the search before either files, as before. The queue limit still bounds a run.
- **Migration/rollback:** none needed; deploy and rollback take effect on the next update or health run.
- **Mixed-version/backward compatibility:** older installations keep filing duplicates until they update; the marker and issue body are unchanged, so new and old runs recognise each other's issues once quoted.
- **Idempotency/retry:** every gate is read-only; an unknown answer declines and the next run retries.
- **Partial failure/recovery:** API failures now delay a migration instead of filing a possible duplicate.
- **Search latency:** a just-filed issue may not be searchable for a short time; the per-run queue limit still bounds any race.

### Complexity Impact

- **Target function:** `_project_config_queue_migration` in `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh`
- **Current line count:** 38 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** -3 lines (the existence block becomes one gate call)
- **Projected post-change:** 35 lines (35% of threshold)
- **Action required:** None — the new helpers are 11 and 24 lines.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/aidevops-cli/aidevops-project-config-lib.sh .agents/scripts/tests/test-update-project-config-safety.sh
bash .agents/scripts/tests/test-update-project-config-safety.sh
/bin/bash .agents/scripts/tests/test-update-project-config-safety.sh
bash .agents/scripts/tests/test-repo-aidevops-health.sh
```

- **Surface mapping:** ShellCheck covers both edited scripts. The update suite on Bash 5 and 3.2 proves the stale-index, lookup-failure and re-queue decisions. The health suite proves the second caller still loads the library.
- **Negative controls:** the new test file run against origin/main fails the stale-index and lookup-failure cases (it files a second and third issue).
- **Production path (read-only):** sourcing the patched library and calling the gates against live repositories: an already-migrated default branch returns `remote_tracks=1` and declines; a repository with open duplicates returns `migration_exists=0` (the unpatched search returns 1 for the same repository).
- **Broad verification trigger:** Not required — one library, no shared contract, root tooling or release infrastructure change.

### Recoverability Checkpoint

- [x] Focused functional verification passes: `bash .agents/scripts/tests/test-update-project-config-safety.sh` (18/18 on Bash 5 and 3.2)
- [x] WIP commit created before broad gates: `wip: t18671 project-config migration issue loop`
- [x] Evidence-triggered broad verification then run: not required — single library, no shared contract

### Scope Boundaries

Initial implementation map. Directly necessary adjacent integration follows
`reference/worker-discipline.md` "Integration scope recovery".

**Hard boundaries:** do not change the issue body, title, labels or marker; do not mutate canonical checkouts; do not make the health keeper skip tracked configs.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request
and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh`
- `.agents/scripts/tests/test-update-project-config-safety.sh`
- `TODO.md`
- `todo/tasks/t18671-brief.md`

## Acceptance Criteria

- [ ] The duplicate search matches an open migration issue or PR.

  ```yaml
  verify:
    method: codebase
    pattern: "MIGRATION_MARKER\}[^ ]. in:body"
    path: ".agents/scripts/aidevops-cli/aidevops-project-config-lib.sh"
  ```

- [ ] A repository whose default branch no longer tracks `.aidevops.json` is never queued, whatever its local index says, and a failed lookup never files.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-update-project-config-safety.sh"
  ```

- [ ] A repository whose default branch still tracks the file is re-queued once its issue closes (regression guarantee).
- [ ] ShellCheck and the update suite on Bash 5 and 3.2 pass.

## Context & Decisions

- **Default branch as the source of truth:** the issue asks for a change on the default branch, so the default branch decides. The local index is still the cheap first filter, so untracked repositories make no API call.
- **REST contents API over GraphQL:** one core-budget request per tracked repository per run keeps the contended GraphQL budget free; HTTP 404 handling follows `quality-feedback-helper.sh` `_fetch_file_on_branch`.
- **Fail closed:** a missed run only delays a migration; a false "none" files a duplicate that a worker is then dispatched to.
- **Not in scope:** closing existing duplicates (maintainer cleanup), and unblocking canonical checkouts that cannot fast-forward past the untracking commit.

## Relevant Files

- `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh:85` — `_project_config_migration_exists`
- `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh:107` — `_project_config_remote_tracks_config`
- `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh:122` — `_project_config_migration_needed`
- `.agents/scripts/repo-aidevops-health-helper.sh:427` — health keeper caller, reached on every scheduled run
- `.agents/scripts/tests/test-update-project-config-safety.sh` — update-path suite

## Dependencies

- **Blocked by:** none
- **Blocks:** worker capacity spent on duplicate and already-resolved migration issues
- **External:** none
