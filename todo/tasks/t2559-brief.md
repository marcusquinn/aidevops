<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2559 — harden worktree cleanup against empty main_worktree_path

## Canonical brief

The canonical brief for this task lives in the linked GitHub issue body: **https://github.com/marcusquinn/aidevops/issues/20205**.

That body contains the complete worker-ready specification — `## What`, `## Session Origin`, `## Why`, `## How` (with all four defensive layers detailed + verbatim code blocks), `## Acceptance Criteria`, `## Files Scope`, and `## Context` — and passes the t2417 worker-ready heuristic (4+ of 7 known heading signals). Per `AGENTS.md`, when the linked issue body is worker-ready the brief file collapses to this stub to avoid brief/issue duplication and the collision surface that duplication creates (see GH#20015).

## Session Origin

User-observed incident. `~/Git/aidevops/` was moved to `~/.Trash/` at 2026-04-20 23:50:01 by an automated worktree cleanup pass. Survived briefly via inode-held pulse writes; auto-recovered by a fresh `git clone` at 2026-04-21 00:02:20. Root-caused and patched in interactive session 2026-04-21.

## Files Scope

- `.agents/scripts/canonical-guard-helper.sh`
- `.agents/scripts/worktree-helper.sh`
- `.agents/scripts/pulse-cleanup.sh`
- `.agents/scripts/pulse-canonical-maintenance.sh`
- `.agents/scripts/tests/test-canonical-trash-guard.sh`
- `TODO.md`
- `todo/tasks/t2559-brief.md`

## PR Conventions

Leaf issue (not `parent-task`) — PR body uses `Resolves #20205`.
