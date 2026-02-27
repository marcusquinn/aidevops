# t1346: Investigate webfetch 46.8% error rate — add retry guidance or fallback

## Origin

- **Created:** 2026-02-27
- **Session:** Claude Code (interactive)
- **Created by:** ai-interactive
- **Parent task:** none
- **Conversation context:** Session miner pulse (2026-02-27) revealed webfetch has a 46.8% error rate across 250 uses. Issue #2441 filed to investigate root causes and add guidance.

## What

Update `prompts/build.txt` and `build-plus.md` with data-driven webfetch error prevention guidance based on root cause analysis of 117 failures. Provide specific alternatives for each failure category.

## Why

Nearly half of all webfetch calls fail, wasting tokens and time. Agents that rely on webfetch for documentation lookups, API reference, or research fail ~50% of the time. The existing guidance (from an earlier pulse) cited outdated stats and lacked specificity about the dominant failure patterns.

## How (Approach)

1. Extract and categorize all 117 webfetch errors from session miner compressed signals
2. Identify root cause categories with percentages
3. Update `prompts/build.txt` error prevention section with specific guidance per category
4. Update `build-plus.md` to reinforce alternatives to webfetch

## Acceptance Criteria

- [x] Root cause categories identified (94% 404, 4% rate limiting, 2% auth)

  ```yaml
  verify:
    method: codebase
    pattern: "46\\.8%|94%.*404|rate.limit"
    path: ".agents/prompts/build.txt"
  ```

- [x] Guidance added for raw.githubusercontent.com alternative (gh api)

  ```yaml
  verify:
    method: codebase
    pattern: "gh api repos.*contents"
    path: ".agents/prompts/build.txt"
  ```

- [x] Guidance added for documentation site alternative (context7 MCP)

  ```yaml
  verify:
    method: codebase
    pattern: "context7 MCP.*resolve-library-id"
    path: ".agents/prompts/build.txt"
  ```

- [x] Rate limiting guidance added

  ```yaml
  verify:
    method: codebase
    pattern: "429.*rate.limit"
    path: ".agents/prompts/build.txt"
  ```

- [ ] Session miner shows improvement in next pulse

  ```yaml
  verify:
    method: manual
    prompt: "Run session-miner-pulse.sh after 1 week and check if webfetch error rate dropped below 20%"
  ```

## Context & Decisions

- Root cause analysis showed 70% of failures are from `raw.githubusercontent.com` URLs that agents construct/guess (mostly from skills audit sessions)
- 23% are from guessed documentation site URLs
- Only 14.5% of failures had any recovery — agents mostly give up after webfetch fails
- Chose to strengthen existing guidance rather than add a new section, keeping instruction count stable
- Updated all error pattern stats to match latest session miner data
- Also updated build-plus.md which had generic "use webfetch" guidance without caveats

## Relevant Files

- `.agents/prompts/build.txt:97-109` — Error prevention section (updated)
- `.agents/build-plus.md:78,122` — Build workflow webfetch references (updated)

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Session miner data analysis |
| Implementation | 15m | Update guidance in 2 files |
| Testing | 5m | Lint checks |
| **Total** | **35m** | |
