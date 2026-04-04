<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief: t15034 - Simplify agent doc .agents/scripts/commands/email-design-test.md

## Origin
- **Session ID:** headless-continuation-contract-v1
- **GitHub Issue:** [GH#15034](https://github.com/marcusquinn/aidevops/issues/15034)

## What
- Tighten and restructure `.agents/scripts/commands/email-design-test.md` (110 lines).
- Follow `tools/build-agent/build-agent.md` guidance.
- Preserve institutional knowledge (task IDs, incident references, error statistics, decision rationale).
- Order by importance (most critical instructions first).
- Split if needed (extract sub-docs with a parent index).
- Use search patterns, not line numbers for references.

## Why
- Automated scan flagged this file for simplification.
- Improving agent efficiency by reducing token usage and focusing on critical instructions.

## How
1. Read `.agents/scripts/commands/email-design-test.md`.
2. Read `tools/build-agent/build-agent.md` for guidance.
3. Identify sections that can be tightened or extracted.
4. Restructure the file to put critical instructions first.
5. Verify that all institutional knowledge is preserved.
6. Run relevant linters (markdownlint).

## Acceptance Criteria
- [ ] Content preservation: all code blocks, URLs, task ID references, and command examples are present.
- [ ] No broken internal links or references.
- [ ] Agent behavior unchanged.
- [ ] Markdownlint passes.
- [ ] PR created and merged.

## Context
- The file is an instruction doc for an agent command.
- It's currently 110 lines.
- The goal is to make it more token-efficient for LLMs.
