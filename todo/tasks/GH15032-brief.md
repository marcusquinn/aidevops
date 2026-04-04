<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief: GH#15032 - Simplify XcodeBuildMCP Agent Doc

## Context
- **Origin**: Headless continuation for issue #15032
- **Issue**: [GH#15032](https://github.com/marcusquinn/aidevops/issues/15032)
- **File**: `.agents/tools/mobile/xcodebuild-mcp.md`

## What
Tighten and restructure the `XcodeBuildMCP` agent documentation to improve token efficiency and clarity, following `tools/build-agent/build-agent.md` guidance.

## Why
Agent docs should be concise and reordered by importance to maximize LLM performance and minimize token costs.

## How
1.  **Classify**: Instruction doc (confirmed).
2.  **Tighten prose**: Compress verbose rules into direct instructions.
3.  **Reorder**: Move critical instructions (Quick Reference, Typical Workflow) to the top.
4.  **Preserve knowledge**: Ensure all command examples, URLs, and key notes are kept.
5.  **Verify**: Run markdown linting and ensure no broken links.

## Acceptance Criteria
- [ ] Prose tightened (byte reduction with zero rule loss).
- [ ] Critical instructions first.
- [ ] YAML frontmatter preserved.
- [ ] AI-CONTEXT block preserved.
- [ ] All command examples and URLs preserved.
- [ ] Markdown linting passes.
