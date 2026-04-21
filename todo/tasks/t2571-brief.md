<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2571 — chore: remove sidelined pre-incident-20260420-2350 canonical clone (after 2026-05-20)

## Canonical brief

The canonical brief for this task lives in the linked GitHub issue body: **https://github.com/marcusquinn/aidevops/issues/20241**.

That body contains the complete worker-ready specification — `## Session Origin`, `## What`, `## Why`, `## How` (with verbatim date-gate + defense-in-depth safety block), `## Acceptance`, `## Files to modify`, and `## Context` — and passes the t2417 worker-ready heuristic (7 of 7 known heading signals). Per `AGENTS.md`, when the linked issue body is worker-ready the brief file collapses to this stub.

## Session Origin

Interactive — post-t2559 follow-up. Filed 2026-04-21 after the canonical-trash incident was fully remediated. The sidelined clone at `~/Git/aidevops-pre-incident-20260420-2350/` was created during Phase 1b recovery to preserve pre-incident packfile layout and reflog; retention window is 30 days.

## Files Scope

- `TODO.md`
- `todo/tasks/t2571-brief.md`

No code files are modified. The task is operational (`mv` into `~/.Trash/` after date check).

## PR Conventions

Date-gated, **no** `#auto-dispatch`. The issue carries the `hold-for-review` label so it will never auto-merge even if a maintainer creates a PR. A worker picked up prematurely will hit the `date +%Y-%m-%d < 2026-05-20` precondition and exit 0 without action — but the issue stays open until the actual deletion lands. Leaf issue — future PR body uses `Resolves #20241`.
