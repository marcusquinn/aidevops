<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2209 Brief — Pre-commit TODO.md duplicate-ID check flags documentation examples as duplicates

**Issue:** GH#19695 (marcusquinn/aidevops) — the issue body is the canonical spec for this task; this brief links the audit trail and records session origin.

## Session origin

Discovered 2026-04-18 from the t2189 interactive session (PR #19682) while attempting to commit the planning PR for six t2189 follow-up tasks (t2197-t2203). The pre-commit hook installed by PR #19683 / t2191 earlier that day activated a dormant `validate_duplicate_task_ids` check in `.agents/scripts/pre-commit-hook.sh:20-50`. The check uses a context-blind `grep -oE '\bt[0-9]+(\.[0-9]+)*\b'` that matches task IDs anywhere in the file — including `## Format` section documentation examples (`t001`, `t001.1`, `t001.1.1` at lines 37-39), inline prose mentions (line 2406: `e.g. - [ ] t001 Task description @owner`), and real completed task entries in `## Done`. All three contexts collapse into "duplicates" under `sort | uniq -d`. Hook was dormant pre-PR #19683 because the `.git/hooks/pre-commit` dispatcher didn't exist. No TODO.md commits landed on main after the hook was installed today, so the bug didn't surface in CI.

This is the seventh t2189 follow-up filing and the one that is ironically blocking its own planning PR from landing.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19695 for:

- Root cause analysis with exact grep pattern and TODO.md line references.
- Three fix options (Option A line-prefix filter is recommended).
- Files to modify: `.agents/scripts/pre-commit-hook.sh:33-35` (regex tightening) + new `.agents/scripts/tests/test-pre-commit-hook-duplicate-ids.sh`.
- Four test scenarios covering doc-examples, real duplicates, Ready↔Done transitions, and active-line collisions.
- Verification commands.

## Acceptance criteria

Listed in the issue body (5 criteria). The key regression: `git commit` on a docs-only TODO.md change must succeed against main's current state, while real `- [ ]`/`- [x]` line collisions must still fail.

## Tier

`tier:standard` — `pre-commit-hook.sh` is 634 lines (over the 500-line `tier:simple` cap), and 5 acceptance criteria exceed the 4-max for simple. Regex change is small but requires understanding which line contexts count as task-list entries versus prose. Sonnet-appropriate.

## Blocks

Blocks committing the t2189 planning PR itself (todo/tasks/t2197-t2203 briefs + TODO.md entries), which includes this brief. Either `--no-verify` bypass with explicit user authorisation, or this fix must land first in its own PR.
