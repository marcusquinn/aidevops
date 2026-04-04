<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t15163: Tighten agent doc Cloudflare Workers Smart Placement

## Context
- **Session Origin**: Headless continuation for issue #15163
- **Issue**: [GH#15163](https://github.com/marcusquinn/aidevops/issues/15163)
- **File**: `.agents/services/hosting/cloudflare-platform-skill/smart-placement.md`

## What
Tighten and restructure the agent documentation for Cloudflare Workers Smart Placement to improve token efficiency and readability while preserving all institutional knowledge.

## Why
The file was flagged by an automated scan for simplification. Reducing token usage in agent documentation improves performance and reduces costs.

## How
1.  **Classify**: Instruction doc (confirmed).
2.  **Tighten Prose**: Remove filler words, use concise language.
3.  **Order by Importance**:
    - Summary/Definition
    - When to Enable / Do NOT enable (Critical)
    - Quick Start (Actionable)
    - Architecture (Context)
    - Requirements & Status (Details)
    - CLI (Tools)
    - See Also (Links)
4.  **Preserve Knowledge**: Ensure all code blocks, URLs, and specific requirements are kept.
5.  **Search Patterns**: Use section headings for internal references.

## Acceptance Criteria
- [ ] Prose is tightened and more concise.
- [ ] Most critical instructions are at the top.
- [ ] All code blocks and URLs are preserved.
- [ ] No institutional knowledge lost.
- [ ] Markdown linting passes.
- [ ] PR created and merged.

## Contextual Notes
- The file is currently 79 lines.
- It's part of the `cloudflare-platform-skill`.
