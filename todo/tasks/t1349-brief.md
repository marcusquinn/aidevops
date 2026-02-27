---
mode: subagent
---
# t1349: fix: webfetch 404 errors — add guidance to prevent raw GitHub URL fetching

## Origin

- **Created:** 2026-02-27
- **Session:** headless:full-loop-t1349
- **Created by:** ai-interactive
- **Conversation context:** Session miner pulse detected 117 webfetch 404 errors (46.8% failure rate). 70% were guessed raw.githubusercontent.com paths. Issue GH#2461 filed.

## What

Strengthen agent guidance across build-plus.md, context-guardrails.md, and context-builder.md to prevent agents from constructing raw.githubusercontent.com URLs or guessing documentation URLs for webfetch. Agents should use `gh api` for GitHub content and Context7 MCP for library docs.

## Why

117 out of 250 webfetch calls fail (46.8%). 70% of failures are agents inventing raw.githubusercontent.com file paths. This wastes tokens, time, and causes cascading retry loops. build.txt already has error prevention guidance but downstream agent docs still recommend the bad patterns.

## How (Approach)

1. `build-plus.md` — add a webfetch decision table to the research section (step 3-4)
2. `context-guardrails.md:127` — replace raw.githubusercontent.com example with `gh api` alternative
3. `context-builder.md:88` — replace `webfetch` GitHub URL with `gh api` approach
4. Verify build.txt guidance is already complete (it is — lines 99-109)

## Acceptance Criteria

- [ ] build-plus.md contains a "what to use instead of webfetch" decision table

  ```yaml
  verify:
    method: codebase
    pattern: "gh api.*repos"
    path: ".agents/build-plus.md"
  ```

- [ ] context-guardrails.md no longer recommends raw.githubusercontent.com

  ```yaml
  verify:
    method: codebase
    pattern: "raw\\.githubusercontent\\.com"
    path: ".agents/tools/context/context-guardrails.md"
    expect: absent
  ```

- [ ] context-builder.md uses gh api instead of webfetch for GitHub repos

  ```yaml
  verify:
    method: codebase
    pattern: "webfetch.*github\\.com/\\{user\\}"
    path: ".agents/tools/context/context-builder.md"
    expect: absent
  ```

- [ ] No raw.githubusercontent.com recommended as a positive pattern in any agent doc

  ```yaml
  verify:
    method: bash
    run: "rg 'raw\\.githubusercontent\\.com' .agents/ --type md -l | grep -v 'build.txt' | xargs -I{} rg -c 'NEVER|CAUTION|avoid|bad|wrong|DON.T' {} | grep ':0$' && exit 1 || exit 0"
  ```
- [ ] Lint clean (shellcheck / markdownlint)

## Context & Decisions

- build.txt already has comprehensive webfetch error prevention (lines 97-109) — no changes needed there
- The fix is about downstream agent docs that still recommend the bad patterns
- raw.githubusercontent.com fails because agents guess file paths that don't exist
- gh api repos/{owner}/{repo}/contents/{path} is the correct alternative (handles auth, returns JSON)
- Context7 MCP is the correct alternative for library/framework documentation

## Relevant Files

- `.agents/prompts/build.txt:97-109` — existing error prevention (verify complete, no changes)
- `.agents/build-plus.md:95-123` — research section needs decision table
- `.agents/tools/context/context-guardrails.md:119-128` — bad example to fix
- `.agents/tools/context/context-builder.md:86-88` — bad example to fix

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Read target files, assess gaps |
| Implementation | 15m | Edit 3 files |
| Testing | 5m | Lint, verify patterns |
| **Total** | **25m** | |
