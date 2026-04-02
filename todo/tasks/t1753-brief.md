# t1753: simplification: tighten agent doc Self-Improvement

## Session Origin
- **User Request:** "/full-loop Implement issue #15056 (https://github.com/marcusquinn/aidevops/issues/15056)"
- **Issue:** GH#15056

## What
Tighten and restructure `.agents/reference/self-improvement.md` following `tools/build-agent/build-agent.md` guidance.

## Why
The file is currently 59 lines and can be more token-efficient while preserving all institutional knowledge.

## How
1.  **Tighten prose:** Compress verbose rules into direct, concise instructions.
2.  **Order by importance:** Move the most critical instructions (e.g., core workflow, security) to the top.
3.  **Preserve knowledge:** Ensure all task IDs (`tNNN`), issue references (`GH#NNN`), and command examples are kept.
4.  **Verify:** Ensure no information loss and that the file is more concise.

## Acceptance Criteria
- [ ] Prose is tightened and more direct.
- [ ] Most critical instructions are at the top.
- [ ] All task IDs (`tNNN`) and issue references (`GH#NNN`) are preserved.
- [ ] Command examples are preserved.
- [ ] No broken links or references.
- [ ] Total line count is reduced without losing rules.

## Context
- **File to simplify:** `.agents/reference/self-improvement.md`
- **Guidance:** `tools/build-agent/build-agent.md`
