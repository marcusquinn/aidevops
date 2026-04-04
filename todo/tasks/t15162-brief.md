---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t15162: simplification: tighten agent doc Model-Specific Subagents

## Origin

- **Created:** 2026-04-01
- **Session:** opencode:gemini-3-flash
- **Created by:** ai-interactive
- **Parent task:** GH#15162
- **Conversation context:** Automated scan flagged `.agents/tools/ai-assistants/models-README.md` for simplification. The file is an instruction doc (97 lines) and needs tightening and restructuring.

## What

Tighten and restructure `.agents/tools/ai-assistants/models-README.md`. The goal is to reduce token usage while preserving all institutional knowledge, rules, and constraints.

## Why

Token optimization. Every token in an agent doc costs on every load. Reducing the size of frequently loaded docs improves performance and reduces costs without losing functionality.

## How (Approach)

1. **Classify:** Already classified as an **Instruction doc**.
2. **Tighten prose:** Compress verbose phrasing into direct rules.
3. **Order by importance:** Move core rules and security-critical instructions to the top.
4. **Use search patterns:** Replace any `file:line_number` references with `rg "pattern"` or section headings.
5. **Preserve knowledge:** Ensure all task IDs (`tNNN`), issue refs (`GH#NNN`), rules, constraints, and command examples are kept.
6. **Verify:** Use `markdownlint-cli2` and ensure no broken links or lost information.

## Acceptance Criteria

- [ ] Prose is tightened and token usage reduced.
  ```yaml
  verify:
    method: bash
    run: "[[ $(wc -l < .agents/tools/ai-assistants/models-README.md) -lt 97 ]]"
  ```
- [ ] All task IDs (`t132.4`) and issue refs are preserved.
  ```yaml
  verify:
    method: codebase
    pattern: "t132.4"
    path: ".agents/tools/ai-assistants/models-README.md"
  ```
- [ ] All command examples and code blocks are preserved.
  ```yaml
  verify:
    method: codebase
    pattern: "```"
    path: ".agents/tools/ai-assistants/models-README.md"
  ```
- [ ] No broken internal links or references.
  ```yaml
  verify:
    method: subagent
    prompt: "Check .agents/tools/ai-assistants/models-README.md for broken links or references."
    files: ".agents/tools/ai-assistants/models-README.md"
  ```
- [ ] Markdown linting passes.
  ```yaml
  verify:
    method: bash
    run: "bunx markdownlint-cli2 .agents/tools/ai-assistants/models-README.md"
  ```

## Relevant Files

- `.agents/tools/ai-assistants/models-README.md` — file to simplify
- `.agents/tools/build-agent/build-agent.md` — guidance for simplification

## Dependencies

- **Blocked by:** None
- **Blocks:** None
- **External:** None

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Read file and guidance |
| Implementation | 30m | Tighten prose and restructure |
| Testing | 10m | Verify with linters and checks |
| **Total** | **50m** | |
