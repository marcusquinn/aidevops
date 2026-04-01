# Task Brief: t15091 - Tighten agent doc Cloudflare Workers AI

## Summary
Tighten and restructure the agent doc `.agents/tools/infrastructure/cloudflare-ai.md` (134 lines).

## Origin
- Session: Headless continuation
- Issue: marcusquinn/aidevops#15091

## What
- Tighten prose and restructure the doc according to `tools/build-agent/build-agent.md` principles.
- Preserve all institutional knowledge (task IDs, incident references, error statistics, decision rationale).
- Order by importance (most critical instructions first).
- Use search patterns instead of line numbers for references.

## Why
- The file was previously simplified but has since been modified, and the content hash no longer matches the post-simplification state.
- Automated scan flagged this file for maintainer review.

## How
- Read `.agents/tools/infrastructure/cloudflare-ai.md`.
- Read `tools/build-agent/build-agent.md` for principles.
- Apply tightening and restructuring.
- Verify content preservation and link integrity.

## Acceptance Criteria
- [ ] Prose is tightened and restructured.
- [ ] All institutional knowledge (task IDs, incident references, etc.) is preserved.
- [ ] Most critical instructions are at the top.
- [ ] No broken internal links or references.
- [ ] Command examples and URLs are preserved.
