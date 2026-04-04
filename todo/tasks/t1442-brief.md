<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1442: Add missing `[Unreleased]` changelog entries needed to unblock the current patch release

## Origin

- **Created:** 2026-03-11
- **Session:** OpenCode interactive request
- **Created by:** OpenCode gpt-5.4
- **Parent task:** none
- **Conversation context:** The user asked for a tracked aidevops planning task that captures the missing `CHANGELOG.md` `[Unreleased]` entries blocking the current patch release. The immediate goal is to secure a valid task ID, linked GitHub issue, and `TODO.md` entry on main so the follow-up changelog work can proceed under the normal workflow.

## What

Update the release planning state so the current patch release has a dedicated task to identify and add any missing `CHANGELOG.md` `[Unreleased]` entries for already-merged changes that should ship in the next patch. The implementation should leave the changelog ready for the release command to produce accurate notes without manual reconstruction of omitted items.

## Why

- The current patch release is blocked by incomplete `[Unreleased]` notes, which means the release cannot proceed with confidence that user-visible changes are documented.
- A tracked task is needed so the missing changelog work is visible to the supervisor, linked to a GitHub issue, and can be picked up using the repo's standard planning workflow.
- Capturing the work now avoids losing the release context between sessions while the patch release is in flight.

## How (Approach)

1. Inspect the current `CHANGELOG.md` `[Unreleased]` section and compare it against the merged fixes intended for the pending patch release.
2. Identify which merged changes still need user-facing entries and group them under the appropriate Keep a Changelog headings.
3. Add the missing `[Unreleased]` bullets with wording that matches the repository's existing changelog style.
4. Verify the release path no longer depends on ad hoc changelog reconstruction for this patch.

## Acceptance Criteria

- [ ] The task identifies the merged patch-release changes that are still missing from `CHANGELOG.md` `[Unreleased]`.
- [ ] `CHANGELOG.md` gains the missing `[Unreleased]` entries needed for the current patch release, written in the repo's existing style.
- [ ] The current patch release is no longer blocked by missing changelog entries.

## Context & Decisions

- Keep this as a small tracked docs/release task rather than bundling it into a broader release-quality task so the release blocker stays explicit.
- Use the standard aidevops planning workflow: atomic task ID claim, linked GitHub issue, `TODO.md` entry on main, and a brief for the follow-up execution.
- Focus the implementation on missing `[Unreleased]` content only; broader release automation or preflight changes belong in separate tasks.

## Relevant Files

- `CHANGELOG.md` — the `[Unreleased]` section that needs the missing patch-release entries.
- `.agents/scripts/version-manager.sh` — release command path that depends on changelog state during patch releases.
- `TODO.md` — planning tracker entry for the task.
- `todo/tasks/t1442-brief.md` — implementation brief for the follow-up work.

## Dependencies

- **Blocked by:** none
- **Blocks:** the pending patch release

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | inspect unreleased notes and recent merged patch fixes |
| Implementation | 10m | add the missing changelog bullets |
| Testing | 10m | verify release notes completeness and release readiness |
| **Total** | **~30m** | |
