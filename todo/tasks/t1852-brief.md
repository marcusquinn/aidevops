---
mode: subagent
---
# t1852: simplification: tighten agent doc Documentation AI Context (.agents/aidevops/docs.md)

## Origin

- **Created:** 2026-04-02
- **Session:** opencode:gemini-3-flash
- **Created by:** ai-interactive
- **Parent task:** GH#15433
- **Conversation context:** Automated scan flagged `.agents/aidevops/docs.md` for simplification. The goal is to tighten the prose and restructure the document according to `build-agent.md` guidance.

## What

A simplified and restructured version of `.agents/aidevops/docs.md` that is more token-efficient while preserving all institutional knowledge.

## Why

The current document is 80 lines and contains verbose prose. Simplifying it reduces the token cost for every agent load that includes this context.

## How (Approach)

1.  Classify the file: Instruction doc.
2.  Tighten prose: Convert narrative to direct rules.
3.  Order by importance: Move critical instructions (Quick Reference, Standards) to the top.
4.  Preserve knowledge: Ensure all task IDs, categories, and structure requirements are kept.
5.  Follow `build-agent.md` guidance: Use search patterns instead of line numbers (though none are currently present).

## Acceptance Criteria

- [ ] Content preservation: all categories, guide structure requirements, and workflow definitions are present.
- [ ] Prose is tightened: narrative sentences are converted to concise rules.
- [ ] Order by importance: Quick Reference and Standards are prominent.
- [ ] No broken internal links or references.
- [ ] Markdown linting passes.
  ```yaml
  verify:
    method: bash
    run: "bunx markdownlint-cli2 .agents/aidevops/docs.md"
  ```

## Relevant Files

- `.agents/aidevops/docs.md` — target for simplification.
- `.agents/tools/build-agent/build-agent.md` — guidance for simplification.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Read docs.md and build-agent.md |
| Implementation | 15m | Tighten prose and restructure |
| Testing | 5m | Markdown lint and manual review |
| **Total** | **25m** | |
