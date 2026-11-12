<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-12
- **Created by:** ai-interactive (requested by the maintainer)
- **Parent task:** none. Builds on #37391 (helper) and #37846 (reliable `status`).
- **Blocked by:** blocked-by:GH#37846 — `status` must read policy details before it can drive automatic applies.
- **Conversation context:** The maintainer gave standing authorization to re-apply the `pull_request_target` Actions event policy automatically whenever a public repository gains or changes such workflows. Today `sync-workflows-helper.sh` only warns (`_warn_event_policy_uncovered`, `.agents/scripts/sync-workflows-helper.sh:1714-1734`), and its PR is not merged when it warns, so the warning cannot apply anything.

## What

Add an opt-in, framework-managed Pulse routine that runs `actions-event-policy-helper.sh status --all-managed` daily and runs `apply --repo <slug>` for each public repository reported `UNCOVERED`, when the install config `safety.actions_event_policy_auto_apply` is `true` (default `false`). Without that config, behaviour is unchanged: the routine reports only.

## Why

GitHub blocks `pull_request_target` by default in public repositories from 2026-12-02 unless an Actions event policy allows the workflow file. A new public repository, or a new gate, triage or sync caller merged into an existing one, is uncovered until someone runs `apply`; its merge gates then end with `startup_failure`, which stops development and Cloudron publication. On 2026-11-12, 13 of 98 managed repositories were uncovered until a manual sweep.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One new routine wrapper plus a config key, following an existing built-in routine pattern; the helper already does the work. Standard rather than simple because it mutates repository settings and needs careful gating.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-routines.sh` — add `_evaluate_event_policy_routine` modelled on `_evaluate_issue_archive_routine` (`:1231-1253`): routine id `r-event-policy`, schedule `${AIDEVOPS_EVENT_POLICY_SCHEDULE:-daily(@05:40)}`, env disable `AIDEVOPS_EVENT_POLICY_ENABLED=0`; register it wherever `_evaluate_issue_archive_routine` is called from `evaluate_routines`.
- `NEW: .agents/scripts/actions-event-policy-routine.sh` — runs `status --all-managed`, parses `UNCOVERED <slug>:` lines, and when `config_get safety.actions_event_policy_auto_apply false` is `true`, runs `apply --repo <slug>` per slug (the helper already audit-logs). Then re-verify with `status --repo <slug>`. Exit 0 when all are covered or applied, 1 when any apply or verify fails. Print a one-line summary per repository. Skip slugs where the token lacks admin (apply returns non-zero; report, don't retry in the same run).
- `EDIT: .agents/configs/aidevops.defaults.jsonc` — add `safety.actions_event_policy_auto_apply: false` with a comment explaining the 2026-12-02 block and that true lets Pulse mutate repository Actions policies.
- `EDIT: .agents/reference/repo-onboarding.md` (step 4, event policy paragraph) — mention the routine and config key.

### Complete Write Surface

- **Callers/readers:** `evaluate_routines` in `pulse-routines.sh`; `config_get` readers.
- **Writers/mutation paths:** `actions-event-policy-helper.sh apply` (existing POST/PUT, audit-logged).
- **Existing verification/tests:** `.agents/scripts/tests/test-actions-event-policy-helper.sh` (fixture pattern for a stub `gh`).
- **Schemas/config:** `.agents/configs/aidevops.defaults.jsonc` new key.
- **Generated/deployed mirrors:** deployed via `setup.sh`.
- **Migrations/backfills:** N/A because the default is off and no stored state changes.
- **Cleanup/rollback paths:** set the key to false or `AIDEVOPS_EVENT_POLICY_ENABLED=0`; applied policies stay and remain valid.

### Implementation Steps

1. Write the routine script, sourcing `shared-constants.sh` and `config-helper.sh` like other routine scripts.
2. Add the evaluator and registration in `pulse-routines.sh`.
3. Add the config default and the onboarding sentence.
4. Run it once with a stubbed `gh` (copy the fixture approach in the existing helper test) to prove the report-only and apply modes.

### Hazards and Compatibility

- **Concurrency/atomicity:** routines already run single-writer per pulse host; `apply` updates in place by name, so a repeat run is idempotent.
- **Migration/rollback:** none.
- **Mixed-version/backward compatibility:** default false keeps other installs report-only.
- **Idempotency/retry:** apply is idempotent; failures retry at the next daily run.
- **Partial failure/recovery:** one repository failing never stops the others; non-zero exit surfaces through routine state.

### Complexity Impact

- **Target function:** new `_evaluate_event_policy_routine` (~22 lines) and new script functions (each < 40 lines). Threshold: 100 lines per function. Action required: none.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/actions-event-policy-routine.sh .agents/scripts/pulse-routines.sh
bash .agents/scripts/tests/test-actions-event-policy-helper.sh
```

- **Surface mapping:** shellcheck covers both scripts; a stubbed-`gh` run proves report-only (config false: no POST/PUT) and apply mode (config true: POST for an uncovered slug, none for a covered one).
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** never apply when the config is false; never touch private/internal repositories (the helper already skips them); do not change the policy body `plan` produces; do not make `sync-workflows` mutate settings.

**AI brief owner:** the maintainer's interactive session that filed this issue.

### Files Scope

- `.agents/scripts/pulse-routines.sh`
- `.agents/scripts/actions-event-policy-routine.sh`
- `.agents/configs/aidevops.defaults.jsonc`
- `.agents/reference/repo-onboarding.md`

## Acceptance Criteria

- [ ] With `safety.actions_event_policy_auto_apply` true, an uncovered public managed repository receives the policy at the next routine run, and `status --repo` then exits 0.
- [ ] With the key false or unset, the routine reports uncovered repositories and makes no POST/PUT calls.
- [ ] Regression guard: covered and private repositories are untouched, and existing helper tests pass.

## Context & Decisions

- Maintainer authorization (2026-11-12): automatic re-apply is approved for this install; the maintainer's session sets the config key to true after merge.
- A routine runs after merge, unlike `sync-workflows`, which warns before its PR merges and so cannot see the new workflow file on the default branch.
