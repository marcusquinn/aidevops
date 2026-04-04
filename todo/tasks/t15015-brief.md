---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t15015: Simplify Dev-Browser agent doc

## Origin

- **Created:** 2026-04-01
- **Session:** headless continuation
- **Created by:** AI DevOps (gemini-3-flash)
- **Issue:** https://github.com/marcusquinn/aidevops/issues/15015

## What

Simplify and restructure `.agents/tools/browser/dev-browser.md` according to `tools/build-agent/build-agent.md` guidance.

## Specification

- Tighten prose, reorder by importance (security, core workflow, edge cases).
- Preserve all institutional knowledge (task IDs, incident references, error statistics, decision rationale).
- Use search patterns (`rg "pattern"`) instead of line numbers for references.
- Ensure all code blocks, URLs, and command examples are preserved.
- Target: reference card style, not tutorial.

## Acceptance Criteria

- [ ] Prose tightened and restructured by importance.
- [ ] Institutional knowledge preserved.
- [ ] Search patterns used for references.
- [ ] All code blocks, URLs, and command examples preserved.
- [ ] Agent behavior unchanged.
- [ ] Markdown linting passes (`markdownlint-cli2`).

## Relevant Files

- `.agents/tools/browser/dev-browser.md`
- `.agents/tools/build-agent/build-agent.md`
