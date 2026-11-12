<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-12
- **Created by:** ai-interactive (requested by the maintainer)
- **Parent task:** none. Docs: `.agents/reference/repo-onboarding.md` (#37837). Cloudron-specific audit: #37831.
- **Blocked by:** none
- **Conversation context:** A newly registered repository had Pulse off, so its `auto-dispatch` task never ran, and nobody noticed. The maintainer asked aidevops to catch missed setup steps automatically for every repository, not only Cloudron packages.

## What

Surface incomplete repository onboarding in the session-start toast, through the existing advisory → `setup-debt-helper.sh` → `aidevops-update-check.sh` path, with low noise:

1. The daily r914 keeper (`repo-aidevops-health-helper.sh`) writes one advisory file per gap repository, `~/.aidevops/advisories/repo-onboarding-<owner>-<repo>.advisory`, and deletes it once the repository is clean.
2. `setup-debt-helper.sh` gains a third debt class, so the toast shows `[WARN] N repos have incomplete aidevops setup — see reference/repo-onboarding.md`, plus a `list-repo-onboarding` command.
3. A report-only `repo-aidevops-health-helper.sh onboarding [--all]` prints the same findings for manual audits; `--all` includes older registrations.

## Why

r914 already detects 73 registered repositories without `.aidevops.json` and 58 unregistered Git repositories (log of 2026-11-11), but only writes them to `~/.aidevops/logs/repo-aidevops-health.log`, which nobody reads (`repo-aidevops-health-helper.sh:530,592`). Surfacing every legacy entry would bury the signal, so advisories are limited to cases that need action.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Additive functions following two in-repo patterns (`_check_required_trust_workflows` in r914 and the SYNC_PAT advisory class in `setup-debt-helper.sh`); the noise rules are specified below, so no design choices remain.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/repo-onboarding-audit-lib.sh` — gap detection and advisory write/delete. It is sourced by r914 so the 1847-line helper grows only by a call, a mode and help text.
- `EDIT: .agents/scripts/repo-aidevops-health-helper.sh:938-990` — call `_check_onboarding_gaps "$dry_run"` from `cmd_check` after `_check_required_trust_workflows`; add the `onboarding [--all]` command to `main`/`cmd_help`.
- `EDIT: .agents/scripts/setup-debt-helper.sh:80-300` — add the prefix `repo-onboarding-`, a collector modelled on `_collect_sync_pat_slugs`, toast/human/json summary lines, and `list-repo-onboarding`.
- `EDIT: .agents/scripts/tests/test-repo-aidevops-health.sh` and `.agents/scripts/tests/test-setup-debt-helper.sh` — fixture cases.
- `EDIT: .agents/scripts/commands/setup-git.md` Phase 1 — run `setup-debt-helper.sh list-repo-onboarding` and walk each repository through `reference/repo-onboarding.md`.
- `EDIT: .agents/reference/repo-onboarding.md` — one line: r914 flags new or blocked repositories in the session toast; `repo-aidevops-health-helper.sh onboarding --all` audits all of them.

### Complete Write Surface

- **Callers/readers:** r914 routine (`.agents/scripts/routines/core-routines.sh` entry `r914`, `repo-aidevops-health-helper.sh run`); `aidevops-update-check.sh:387-394` reads `setup-debt-helper.sh summary --format=toast`; `/setup-git` reads the list commands.
- **Writers/mutation paths:** only `~/.aidevops/advisories/repo-onboarding-*.advisory` (create/delete). Never edits `repos.json`, labels, workflows or repositories, and never files GitHub issues, because private repository names must not reach public issues.
- **Existing verification/tests:** `test-repo-aidevops-health.sh`, `test-setup-debt-helper.sh`.
- **Schemas/config:** reads existing `repos.json` fields `initialized`, `pulse`, `maintenance`, `local_only`, `role`, `path`, `slug`; new env `AIDEVOPS_ONBOARDING_RECENT_DAYS` (default 30).
- **Generated/deployed mirrors:** deployed copies refresh via `setup.sh`.
- **Migrations/backfills:** N/A because advisories are regenerated from scratch each daily run.
- **Cleanup/rollback paths:** `rm ~/.aidevops/advisories/repo-onboarding-*.advisory` after revert; `aidevops security dismiss repo-onboarding-<owner>-<repo>` silences one repository (existing `dismissed.txt` handling in `setup-debt-helper.sh:92`).

### Implementation Steps

1. Candidate set (same filter as `_check_required_trust_workflows`, `repo-aidevops-health-helper.sh:888-893`, but without requiring `pulse == true`): `maintenance != false`, `local_only != true`, role `maintainer`, non-empty `slug`, `path` exists.
2. A candidate is **in scope for an advisory** when either:
   - **recent:** `initialized` is within `AIDEVOPS_ONBOARDING_RECENT_DAYS` days (ISO 8601 UTC; compare with `date -u` epoch via `jq 'fromdateiso8601'`), or
   - **blocked dispatch:** `pulse != true` and `gh issue list --repo <slug> --label auto-dispatch --state open --limit 1 --json number` returns at least one issue.

   `onboarding --all` reports every candidate regardless of scope.
3. Gaps for an in-scope repository: `pulse != true` (recent repos only, or blocked dispatch); missing `${path}/.aidevops.json`; `gh api repos/<slug>/labels/auto-dispatch` returns HTTP 404. Treat any other GitHub error as unknown: log it, do not write or delete that repository's advisory.
4. Advisory body: the slug, one line per gap with its fix command (`aidevops init`, `aidevops repos pulse on <slug>`, `label-sync-helper.sh sync --repo <slug>`), and a pointer to `reference/repo-onboarding.md`. Delete the file when an in-scope repository has no gaps or leaves scope. `AIDEVOPS_REPO_HEALTH_DRY_RUN=1` logs only.
5. Log a count line `onboarding: N advisories, M clean, K unknown` like the trust-workflows summary.
6. `setup-debt-helper.sh`: mirror `_collect_sync_pat_slugs`/`_slug_from_filename` for the new prefix, add the class to the human, toast and json summaries (toast text above, singular/plural like lines 220-232), and `list-repo-onboarding`. Keep "quiet on clean": no output and exit 0 when all classes are empty.

### Hazards and Compatibility

- **Concurrency/atomicity:** r914 already holds its lock; write advisories via temp file plus `mv`.
- **Migration/rollback:** none needed; advisories are disposable.
- **Mixed-version/backward compatibility:** entries without `initialized` are not "recent"; they surface only through blocked dispatch or `--all`.
- **Idempotency/retry:** each run rewrites or deletes the same file per repository; unknown GitHub state leaves the previous file untouched.
- **Partial failure/recovery:** a GitHub error for one repository must not stop the loop or count as clean; r914's exit code stays driven by bump and trust failures only.
- Noise budget: with today's registry this yields advisories only for repositories registered in the last 30 days or with stranded `auto-dispatch` issues, not the 73 + 58 legacy detections.

### Complexity Impact

- **Target function:** `cmd_check` in `.agents/scripts/repo-aidevops-health-helper.sh`
- **Current line count:** 53 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +2 lines
- **Projected post-change:** 55 lines (55% of threshold)
- **Action required:** None. All new logic lives in the new lib in functions under 60 lines each.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-repo-aidevops-health.sh
bash .agents/scripts/tests/test-setup-debt-helper.sh
bash .agents/scripts/tests/test-sync-pat-detection.sh
shellcheck .agents/scripts/repo-onboarding-audit-lib.sh .agents/scripts/repo-aidevops-health-helper.sh .agents/scripts/setup-debt-helper.sh
```

- **Surface mapping:** fixture `repos.json` with a stubbed `gh` proves: a recent entry with Pulse off, no `.aidevops.json` and a 404 label writes one advisory listing three gaps; an old entry with Pulse off and no open `auto-dispatch` issue writes none; an old entry with Pulse off and an open `auto-dispatch` issue writes one; a repository that becomes clean has its advisory deleted; a non-404 GitHub error leaves an existing advisory unchanged; dry run writes nothing. Setup-debt tests prove the new toast line, singular/plural, dismissal, and quiet-on-clean. The SYNC_PAT test guards the shared advisory directory.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** report and advisory only. Never enable Pulse, sync labels, run `aidevops init`, install workflows or file issues. Do not change r914's schedule or the existing missing-folder and no-init log lines. Cloudron-specific checks stay in #37831.

**AI brief owner:** the maintainer's interactive session that filed this issue.

### Files Scope

- `.agents/scripts/repo-onboarding-audit-lib.sh`
- `.agents/scripts/repo-aidevops-health-helper.sh`
- `.agents/scripts/setup-debt-helper.sh`
- `.agents/scripts/tests/test-repo-aidevops-health.sh`
- `.agents/scripts/tests/test-setup-debt-helper.sh`
- `.agents/scripts/commands/setup-git.md`
- `.agents/reference/repo-onboarding.md`

## Acceptance Criteria

- [ ] After r914 runs, a repository registered within 30 days with Pulse off, no `.aidevops.json` or no `auto-dispatch` label has an advisory, and the session toast shows the repo-onboarding `[WARN]` line.
- [ ] An older repository with Pulse off and an open `auto-dispatch` issue gets an advisory; `repo-aidevops-health-helper.sh onboarding --all` lists every maintained candidate's gaps.
- [ ] Regression guard: older repositories without stranded `auto-dispatch` issues produce no advisory, a clean repository's advisory is deleted, the audit never edits repositories or files issues, and the existing r914, setup-debt and SYNC_PAT tests pass.

## Context & Decisions

- Advisories rather than GitHub issues: the gaps are in the maintainer's local registry, and issue titles would expose private repository names.
- Pulse off is not a gap on its own; 26 of 95 maintained repositories have it off deliberately. It is a gap only for new registrations or when `auto-dispatch` issues are stranded.
