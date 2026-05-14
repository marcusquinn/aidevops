# t3590 — fix(phase-filing): skip closed parent auto-file

## Goal

Prevent `auto_file_next_phase()` from creating new child issues from closed or superseded parent-task issues.

## Context

- Issue: GH#23526
- Approved by maintainer with crypto signature on 2026-05-14.
- Current code reads parent `body` and `title` but not `.state`, so a closed parent with armed `[auto-fire:on-prior-merge]` markers can still file the next phase after a descendant child PR merges.

## Files

- `.agents/scripts/shared-phase-filing.sh`
- `.agents/scripts/tests/test-shared-phase-filing.sh`
- `TODO.md`

## Implementation

1. Extend the parent issue API projection in `auto_file_next_phase()` to include `state`.
2. Parse `parent_state` after `parent_body` and `parent_title`.
3. Return early unless `parent_state == open`, logging the skip reason.
4. Add regression coverage for:
   - closed parent with an armed next phase creates no child;
   - open parent with the same phase fixture still files the next phase.

## Verification

- `bash .agents/scripts/tests/test-shared-phase-filing.sh`
- `shellcheck .agents/scripts/shared-phase-filing.sh .agents/scripts/tests/test-shared-phase-filing.sh`
- `.agents/scripts/linters-local.sh`

## Release

- Open a PR titled with `t3590` and `Resolves #23526`.
- After green checks and merge, release via the repository version workflow/script.
