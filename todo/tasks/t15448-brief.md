<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief: t15448 - Simplification: tighten agent doc Crawl4AI Integration Guide

## Context
- **Session Origin**: Headless worker dispatch
- **Issue**: [GH#15448](https://github.com/marcusquinn/aidevops/issues/15448)
- **File**: `.agents/tools/browser/crawl4ai-integration.md`

## What
Tighten and restructure the Crawl4AI Integration Guide to improve token efficiency and readability for agents.

## Why
The file was flagged by an automated scan as a candidate for simplification (73 lines). Reducing verbosity while preserving institutional knowledge helps agents process context faster and more accurately.

## How
1. **Classify**: This is an **instruction doc** (setup, reference, troubleshooting).
2. **Tighten prose**: Remove filler words, use concise bullet points.
3. **Order by importance**: Ensure Quick Reference and core setup are prominent.
4. **Preserve knowledge**: Keep all task IDs, URLs, command examples, and decision rationale.
5. **Verify**: Ensure no broken links, all code blocks preserved, and agent behavior remains unchanged.

## Acceptance Criteria
- [ ] File size reduced (lines/tokens)
- [ ] All institutional knowledge (URLs, commands, task IDs) preserved
- [ ] No broken internal links
- [ ] PR opened with `{task-id}: {description}` format
- [ ] Signature footer included in PR and closing comments
