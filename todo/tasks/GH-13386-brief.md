<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#13386: Tighten .agents/scripts/commands/readme.md

## Session Origin
Interactive user session — `/full-loop` invocation with GitHub issue reference.

## What
Simplify `.agents/scripts/commands/readme.md` (136 lines) by removing redundant prose while preserving all institutional knowledge.

## Why
The file contains verbose explanations and repetitive "when to use" sections that can be compressed without losing information. This follows the agent doc simplification pattern from `tools/build-agent/build-agent.md`.

## How
1. **Classify**: This is an instruction doc (agent command), not a reference corpus — compress prose, reorder by importance, don't remove knowledge.
2. **Compress Steps 1-5**: Merge verbose step descriptions; remove repetitive explanations.
3. **Tighten "When to use" sections**: Combine into concise bullets.
4. **Simplify Examples**: Remove redundant comments; keep all command variants.
5. **Relocate Dynamic Counts**: Move aidevops-specific section to a note or separate doc reference.
6. **Preserve all**: Section mapping table, command examples, workflow references, related links.
7. **Target**: ~100-110 lines (25-30% reduction).

## Acceptance Criteria
- [ ] All code blocks, URLs, and command examples preserved
- [ ] No broken internal references
- [ ] Section mapping table intact
- [ ] Line count reduced to 100-110 lines
- [ ] Markdown linting passes (markdownlint-cli2)
- [ ] PR created with `Closes #13386`

## Context
Issue #13386 is a simplification-debt item flagged by automated scan. The issue description provides guidance on instruction doc tightening: preserve knowledge, order by importance, split if needed, use search patterns not line numbers.
