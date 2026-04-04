<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t15128: Simplification of wrangler-patterns.md

## Context
- **Session Origin**: Headless continuation (GH#15128)
- **Issue**: [GH#15128](https://github.com/marcusquinn/aidevops/issues/15128)
- **File**: `.agents/services/hosting/cloudflare-platform-skill/wrangler-patterns.md`

## What
Tighten and restructure the Wrangler Development Patterns agent doc.

## Why
The file was flagged for simplification to improve agent efficiency and reduce context noise.

## How
1. **Classify**: Instruction doc (confirmed).
2. **Tighten**: Compress prose while preserving all commands, code blocks, and institutional knowledge.
3. **Restructure**: Order by importance (Security/Core -> Edge cases).
4. **References**: Ensure no stale line number references (none found in initial read).
5. **Verify**: Content preservation and no broken links.

## Acceptance Criteria
- [ ] Prose is tightened and more concise.
- [ ] All code blocks and commands from the original are preserved.
- [ ] Sections are ordered by importance.
- [ ] No broken internal links.
- [ ] Total line count is reduced without losing knowledge.

## Context
The file contains common Wrangler workflows (KV, D1, Environments, Testing, etc.). It's currently 106 lines.
