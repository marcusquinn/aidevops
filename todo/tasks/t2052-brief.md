<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t2052: Simplification: tighten agent doc Longform Talking-Head Pipeline

## Context
- **Session Origin**: Headless continuation (GH#15449)
- **Task ID**: t2052
- **File**: `.agents/content/production-video-08-talking-head-pipeline.md`

## What
Tighten and restructure the agent doc for the Longform Talking-Head Pipeline. The goal is to reduce line count while preserving all institutional knowledge, following the guidance in `tools/build-agent/build-agent.md`.

## Why
The file was flagged by an automated scan for simplification. Reducing the size of agent docs improves token efficiency and focus for LLMs.

## How
1.  **Classify**: Instruction doc (confirmed).
2.  **Tighten Prose**: Remove filler words, use concise language.
3.  **Order by Importance**: Ensure the most critical steps and rules are at the top.
4.  **Preserve Knowledge**: Keep all tool names, quality metrics, cost info, and specific command examples.
5.  **Verify**: Ensure no content loss and that the doc remains functional.

## Acceptance Criteria
- [ ] Line count reduced (original: 73 lines).
- [ ] All institutional knowledge preserved (tools, costs, commands).
- [ ] Most critical instructions prioritized.
- [ ] No broken links or references.
- [ ] Doc remains clear and actionable.
