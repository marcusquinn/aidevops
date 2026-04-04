<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t15051: Simplify memory-log.md

## Context
- **Session Origin**: Headless continuation for issue #15051
- **Issue**: [GH#15051](https://github.com/marcusquinn/aidevops/issues/15051)
- **File**: `.agents/scripts/commands/memory-log.md`

## What
Tighten and restructure the agent doc `.agents/scripts/commands/memory-log.md`.

## Why
The file was flagged for simplification to improve LLM efficiency and maintainability.

## How
1. Determine file type: Instruction doc.
2. Tighten prose while preserving institutional knowledge.
3. Order by importance: Workflow, Auto-capture triggers, Privacy, Related.
4. Use search patterns instead of line numbers (if any).
5. Ensure all code blocks, URLs, task ID references, and command examples are preserved.

## Acceptance Criteria
- [ ] Prose is tightened and restructured.
- [ ] Institutional knowledge preserved (task IDs, incident references, etc.).
- [ ] Ordered by importance.
- [ ] All code blocks and command examples preserved.
- [ ] No broken internal links.
- [ ] `markdownlint-cli2` passes.

## Context
The file is an instruction doc for the `memory-log` command, which shows recent auto-captured memories.
