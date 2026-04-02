---
mode: subagent
---
# GH#15033: simplification: tighten agent doc Cloudflare Zaraz

## Origin

- **Created:** 2026-04-02
- **Session:** opencode:gemini-3-flash
- **Created by:** ai-supervisor
- **Conversation context:** Automated scan flagged .agents/services/hosting/cloudflare-platform-skill/zaraz.md for simplification.

## What

Tighten and restructure the Cloudflare Zaraz agent doc to reduce token usage while preserving all institutional knowledge and examples.

## Why

Reduce context overhead for agents using the Cloudflare platform skill.

## How (Approach)

- Compress prose and merge redundant sections.
- Preserve all code blocks and URLs.
- Fix pre-existing frontmatter issues in related skill files discovered during linting.
- Update simplification-state.json with the new file hash.

## Acceptance Criteria

- [x] .agents/services/hosting/cloudflare-platform-skill/zaraz.md is tightened (line count reduced).
  ```yaml
  verify:
    method: bash
    run: "[[ $(wc -l < .agents/services/hosting/cloudflare-platform-skill/zaraz.md) -lt 102 ]]"
  ```
- [x] Institutional knowledge and examples are preserved.
- [x] Related skill frontmatter issues fixed.
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh | grep -q 'Skill frontmatter: 13 skills validated, all have correct '\''name'\'' field'"
  ```
- [x] simplification-state.json updated.
  ```yaml
  verify:
    method: codebase
    pattern: ".agents/services/hosting/cloudflare-platform-skill/zaraz.md"
    path: ".agents/configs/simplification-state.json"
  ```

## Relevant Files

- `.agents/services/hosting/cloudflare-platform-skill/zaraz.md` — Main file to tighten.
- `.agents/services/hosting/cloudflare-platform-skill.md` — Frontmatter fix.
- `.agents/services/communications/convos.md` — Frontmatter fix.
- `.agents/tools/ui/nothing-design-skill.md` — Frontmatter fix.
- `.agents/configs/simplification-state.json` — State tracking.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Read file and guidance |
| Implementation | 15m | Tightening and fixes |
| Testing | 5m | Linters |
| **Total** | **25m** | |
