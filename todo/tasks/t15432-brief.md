# Task Brief: t15432 - Agent doc simplification for seo-writer.md

## Context
- **Session Origin**: Headless continuation (GH#15432)
- **Issue**: [GH#15432](https://github.com/marcusquinn/aidevops/issues/15432)
- **File**: `.agents/content/seo-writer.md`

## What
Tighten and restructure the `seo-writer.md` agent doc. It has been classified as an **instruction doc**.

## Why
To improve LLM performance by reducing token count and ordering instructions by importance (primacy effect).

## How
1. **Tighten prose**: Remove filler words while preserving all institutional knowledge.
2. **Order by importance**: Move critical instructions (security, core workflow) to the top.
3. **Preserve knowledge**: Keep all task IDs, incident references, and decision rationale.
4. **Use search patterns**: Replace `file:line_number` with `rg "pattern"` or section headings.
5. **Verification**: Ensure all code blocks, URLs, and command examples are preserved.

## Acceptance Criteria
- [x] Prose is tightened (reduced line count/token count).
- [x] Instructions are ordered by importance.
- [x] All institutional knowledge (task IDs, URLs, commands) is preserved.
- [x] No broken references.
- [x] Agent behavior remains unchanged.
