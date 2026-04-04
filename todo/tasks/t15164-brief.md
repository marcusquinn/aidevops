<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t15164: Simplification of .agents/seo/seo-optimizer.md

## Context
- **Session Origin**: Headless continuation for issue #15164
- **Issue**: [GH#15164](https://github.com/marcusquinn/aidevops/issues/15164)
- **File**: `.agents/seo/seo-optimizer.md`
- **Classification**: Instruction doc

## What
Tighten and restructure the SEO Optimizer agent documentation to improve LLM efficiency while preserving all institutional knowledge.

## Why
Smaller, better-structured agent docs reduce token usage and improve model adherence to instructions (primacy effect).

## How
1.  **Tighten prose**: Remove filler words, use concise bullet points.
2.  **Reorder by importance**:
    -   Core Purpose & Quick Reference
    -   Workflow (how to use it)
    -   On-Page Checklist (the rules)
    -   Featured Snippet Optimisation (specialized rules)
    -   Integration (relationships)
3.  **Preserve knowledge**: Keep all checklist items, script references, and integration points.
4.  **Verification**:
    -   Content preservation (all code blocks, URLs, task IDs, command examples).
    -   Markdown linting.
    -   Line count reduction (target < 60 lines).

## Acceptance Criteria
- [ ] Prose is tightened and filler removed.
- [ ] Sections are reordered by importance (Workflow before Checklist).
- [ ] All technical details (script names, checklist items) are preserved.
- [ ] No broken links or references.
- [ ] Markdown linting passes.
- [ ] PR created and merged.
