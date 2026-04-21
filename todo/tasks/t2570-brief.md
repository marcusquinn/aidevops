<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2570 — scanner: detect empty-compare foot-gun bash pattern

## Canonical brief

The canonical brief for this task lives in the linked GitHub issue body: **https://github.com/marcusquinn/aidevops/issues/20239**.

That body contains the complete worker-ready specification — `## Session Origin`, `## What`, `## Why`, `## How` (with detection algorithm, allowlist, CI-integration phasing, test strategy), `## Acceptance`, `## Files to modify`, and `## Context` — and passes the t2417 worker-ready heuristic (7 of 7 known heading signals). Per `AGENTS.md`, when the linked issue body is worker-ready the brief file collapses to this stub to avoid brief/issue duplication and the collision surface that duplication creates (see GH#20015).

## Session Origin

Interactive — post-t2559 follow-up. Filed 2026-04-21 after the canonical-trash incident was fully remediated (PR #20209, issue #20205, four defensive layers deployed and running in production pulse PID 14665). The scanner targets the latent class of bug that caused that incident.

## Files Scope

- `.agents/scripts/empty-compare-scanner.sh`
- `.agents/scripts/tests/test-empty-compare-scanner.sh`
- `.agents/configs/empty-compare-allowlist.txt`
- `.github/workflows/empty-compare-gate.yml`
- `TODO.md`
- `todo/tasks/t2570-brief.md`

## PR Conventions

Leaf issue (not `parent-task`) — PR body uses `Resolves #20239`.
