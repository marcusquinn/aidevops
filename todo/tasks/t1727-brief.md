<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t1727: Simplification: tighten agent doc Ahrefs SEO Integration

## Session Origin
- **User Request**: `/full-loop Implement issue #15129 (https://github.com/marcusquinn/aidevops/issues/15129) -- Simplification: tighten agent doc Ahrefs SEO Integration. Reduce line count while preserving all essential information.`
- **Task ID**: `t1727`

## What
- Simplify `.agents/seo/ahrefs.md` to reduce line count.
- Preserve all essential information (API endpoints, auth, common params).
- Target: Significant reduction from 106 lines.

## Why
- Improve readability and maintainability of agent documentation.
- Reduce token usage when the agent reads this file.

## How
- Combine sections where possible.
- Use more concise Markdown formatting.
- Shorten tables and code blocks.
- Remove redundant text.

## Acceptance Criteria
- [x] `.agents/seo/ahrefs.md` line count is significantly reduced (e.g., < 80 lines).
- [x] All essential API endpoints and auth instructions are still present.
- [x] Documentation remains clear and usable by an AI agent.
- [x] No loss of functional information.

## Context
- The file is a subagent definition for Ahrefs SEO integration.
- It uses direct `curl` commands instead of an MCP.
- Auth is handled via `AHREFS_API_KEY` in `~/.config/aidevops/credentials.sh`.
