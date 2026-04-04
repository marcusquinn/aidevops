<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1434: Fix `gh` mutation commands failing with `/bin/zsh` `posix_spawn` error

## Origin

- **Created:** 2026-03-11
- **Session:** opencode:gpt-5.4 release follow-up
- **Created by:** human request during release/deploy follow-up
- **Conversation context:** After releasing the provider-aware headless runtime, mutating `gh` commands failed locally with `ENOENT: no such file or directory, posix_spawn '/bin/zsh'` while read-only `gh` commands still worked. User asked for a TODO and detailed plan for the fix.

## What

Investigate and fix intermittent failures in mutating GitHub CLI commands (`gh pr merge`, `gh api` writes, issue comment/close paths) that currently fail with `/bin/zsh` `posix_spawn` errors in aidevops sessions.

## Why

This breaks the expected full-loop and release lifecycle. The framework can still ship changes via local git fallback, but that bypasses part of the intended GitHub automation path and reduces reliability for future autonomous sessions.

## How

1. Reproduce the failure in a minimal command matrix covering read vs write `gh` commands.
2. Check shell/environment sources (`SHELL`, editor/pager config, inherited env, worktree differences, gh config).
3. Implement the narrowest fix and add a deterministic verification step for future sessions.

## Acceptance Criteria

- Mutating `gh` commands succeed in the same runtime where read-only `gh` commands already succeed.
- Full-loop merge/comment/close steps no longer require local git fallback.
- A reproducible verification command or helper exists for regression checks.

## Context

- Related issue: `GH#4122`
- Related PR/release context: `PR #4116`, release `v2.171.1`
- Detailed execution plan: `todo/PLANS.md#2026-03-11-gh-mutation-zsh-posix_spawn-failure`
