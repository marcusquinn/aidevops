<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief: GH#15363 - Tighten agent doc Nothing-Inspired UI/UX Design System

## Session Origin
- Interactive session (worker run)
- Issue: https://github.com/marcusquinn/aidevops/issues/15363

## What
- Tighten and restructure `.agents/tools/ui/nothing-design-skill.md`.
- Current size: 180 lines.
- Goal: Prose tightening and restructuring into chapters.

## Why
- Automated scan flagged the file for simplification debt.
- Improve token efficiency and organization.

## How
- Tighten prose in all sections.
- Extract major sections into chapter files in `.agents/tools/ui/nothing-design-skill/`.
- Update the main file to be a slim index.
- Fix any markdown linting errors.
- Update subagent index.

## Acceptance Criteria
- [x] Prose tightened (verbose phrasing removed, institutional knowledge preserved).
- [x] Restructured into chapters: `01-philosophy.md`, `02-craft-rules.md`, `03-anti-patterns.md`, `04-workflow.md`.
- [x] Main file is a slim index (~25 lines).
- [x] All code blocks, URLs, and examples preserved.
- [x] Markdown linting passes.
- [x] Subagent index updated.

## Context
- File: `.agents/tools/ui/nothing-design-skill.md`
- Sub-directory: `.agents/tools/ui/nothing-design-skill/`
- Guidance: `tools/build-agent/build-agent.md`, `tools/code-review/code-simplifier.md`
