# Task Brief - t15173: Simplify .agents/health.md

## Session Origin
- GitHub Issue: https://github.com/marcusquinn/aidevops/issues/15173
- Trigger: Automated simplification scan

## What
- Tighten and restructure `.agents/health.md`.
- Classify as "Instruction doc".
- Compress prose while preserving institutional knowledge.
- Order by importance.
- Use search patterns instead of line numbers for references (though none currently exist in the file).

## Why
- Improve agent efficiency by reducing instruction budget.
- Ensure most critical instructions are weighted more heavily by the LLM.

## How
- Review `.agents/health.md`.
- Tighten the "Role" and "Quick Reference" sections.
- Reorder sections if necessary (Role and Disclaimer are already at the top).
- Ensure "Important Notice" (Disclaimer) is prominent.
- Verify content preservation.

## Acceptance Criteria
- Content preservation: all code blocks, URLs, task ID references, and command examples must be present.
- Prose is tightened and more concise.
- No broken internal links or references.
- Agent behaviour unchanged.

## Context
- File is currently 71 lines.
- It's a subagent definition for health and wellness.
