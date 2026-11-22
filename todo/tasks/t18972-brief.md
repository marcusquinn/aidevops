<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-12
- **Created by:** ai-interactive (requested by the maintainer)
- **Parent task:** none. Companion: `.agents/tools/deployment/cloudron-package-onboarding.md` (#37830)
- **Blocked by:** none
- **Conversation context:** After writing the Cloudron package onboarding checklist, the maintainer asked for the equivalent playbook for all other repositories. Registration via `aidevops repos add` or auto-discovery skips init, labels, workflows, secrets and branch protection, and nothing reports it.

## What

A general repository onboarding checklist at `.agents/reference/repo-onboarding.md`, linked from the repo-registration rule in `reference/task-lifecycle.md`, from `/setup-git`, and from the Cloudron checklist, which becomes its type-specific extension.

## Why

The only registration guidance was one paragraph in `reference/task-lifecycle.md` covering `repos.json` and `SYNC_PAT`. `aidevops check-workflows` exits 0 for missing workflows, so gaps stay invisible.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** Documentation only; facts verified against the live helpers in the authoring session.

## How (Approach)

### Files to Modify

- `NEW: .agents/reference/repo-onboarding.md` — seven-step checklist (init, Pulse/maintenance, labels, opt-in managed workflows, SYNC_PAT, branch protection, type-specific steps).
- `EDIT: .agents/reference/task-lifecycle.md:267` — pointer.
- `EDIT: .agents/scripts/commands/setup-git.md:29` — pointer.
- `EDIT: .agents/tools/deployment/cloudron-package-onboarding.md:19` — pointer to the general checklist.

### Complete Write Surface

- **Callers/readers:** agents reading `reference/task-lifecycle.md`, `scripts/commands/setup-git.md` and the Cloudron checklist.
- **Writers/mutation paths:** N/A because the change is documentation only.
- **Existing verification/tests:** markdownlint in `linters-local.sh`.
- **Schemas/config:** N/A because no config changes.
- **Generated/deployed mirrors:** deployed by `setup.sh` to `~/.aidevops/agents/`.
- **Migrations/backfills:** N/A because the change is documentation only.
- **Cleanup/rollback paths:** N/A because reverting the PR restores prior docs.

### Implementation Steps

1. Write the checklist, verifying each command against its helper's `--help`.
2. Add the three pointers.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because the change is documentation only.
- **Migration/rollback:** N/A because no stored state.
- **Mixed-version/backward compatibility:** N/A because no runtime change.
- **Idempotency/retry:** N/A because no runtime change.
- **Partial failure/recovery:** N/A because no runtime change.

### Complexity Impact

- **Target function:** N/A because documentation only.
- **Action required:** None.

### Verification Before Dispatch

```bash
git diff --stat origin/main
npx --no-install markdownlint-cli2 .agents/reference/repo-onboarding.md .agents/reference/task-lifecycle.md .agents/scripts/commands/setup-git.md .agents/tools/deployment/cloudron-package-onboarding.md
```

- **Surface mapping:** markdownlint covers all four files; commands were exercised against a live registered repository during authoring.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** no script changes; automated auditing is a separate task.

**AI brief owner:** the maintainer's interactive session.

### Files Scope

- `.agents/reference/repo-onboarding.md`
- `.agents/reference/task-lifecycle.md`
- `.agents/scripts/commands/setup-git.md`
- `.agents/tools/deployment/cloudron-package-onboarding.md`

## Acceptance Criteria

- [ ] `reference/repo-onboarding.md` exists and every command in it matches current helper usage.
- [ ] The registration rule, `/setup-git` and the Cloudron checklist link to it.
- [ ] Regression guard: markdownlint passes on all four files.

## Context & Decisions

- Managed workflows are documented as opt-in: most registered repositories have no `issue-sync`, and Pulse falls back for triage.
