<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief: t15364 - simplification: tighten agent doc .agents/scripts/commands/full-loop.md

## Origin
- **Session**: Headless worker run
- **Issue**: [GH#15364](https://github.com/marcusquinn/aidevops/issues/15364)

## What
Tighten and restructure the agent doc `.agents/scripts/commands/full-loop.md` to improve token efficiency and clarity.

## Why
The file is currently 161 lines long and has been flagged for simplification. Reducing token usage while preserving all institutional knowledge is a core framework goal.

## How
1.  Read `.agents/scripts/commands/full-loop.md`.
2.  Apply prose tightening as per `tools/build-agent/build-agent.md`.
3.  Preserve all task IDs (`tNNN`), issue refs (`GH#NNN`), rules, paths, and command examples.
4.  Order instructions by importance (most critical first).
5.  Verify the changes with `markdownlint-cli2`.

## Acceptance Criteria
- [ ] Prose is tightened and redundant examples removed.
- [ ] All institutional knowledge (task IDs, issue refs, rules) is preserved.
- [ ] Instructions are ordered by importance.
- [ ] `markdownlint-cli2` passes.
- [ ] Agent behavior remains unchanged (as assessed by self-review).

## Context
- **File**: `.agents/scripts/commands/full-loop.md`
- **Guidance**: `.agents/tools/build-agent/build-agent.md`
- **Current size**: 161 lines
