---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1862: simplification: reduce function complexity in higgsfield-*.mjs trio

## Origin

- **Created:** 2026-04-03
- **Session:** opencode:qlty-maintainability-recovery
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability grade dropped from A to C. The three higgsfield files have a combined complexity of 1049 — the single largest contributor group. They contain 143 functions total with multiple high-complexity hot spots.

## What

Reduce combined complexity of the three higgsfield files from 1049 to under 300:
- `.agents/scripts/higgsfield/higgsfield-commands.mjs` (2218 lines, complexity 406, 48 functions)
- `.agents/scripts/higgsfield/higgsfield-video.mjs` (1374 lines, complexity 345, 36 functions)
- `.agents/scripts/higgsfield/higgsfield-common.mjs` (1456 lines, complexity 298, 59 functions)

First decision: determine whether these files are **authored code** requiring refactoring, or **generated/vendored code** that should be excluded from qlty analysis.

## Why

- Combined 1049 complexity points = ~80% of total codebase smells
- If these are actively maintained, they desperately need decomposition
- If these are generated or vendored, excluding them from qlty would immediately recover the A grade
- Either path achieves the goal — the decision determines effort level

## How (Approach)

### Step 1: Triage (critical first step)
1. Read file headers, comments, and git log to determine authorship
2. Check if files are auto-generated (look for `@generated`, `// DO NOT EDIT`, codegen markers)
3. Check if files are vendored (copied from an external project)
4. **If generated/vendored**: add to `.qlty/qlty.toml` `exclude_patterns` and close task — 15 minutes
5. **If authored**: proceed with full decomposition below

### Step 2: Decomposition (if authored code)

For each file, apply the same patterns:

**higgsfield-commands.mjs** (406 complexity, 48 functions):
- Extract command handlers into individual files: `commands/generate.mjs`, `commands/list.mjs`, etc.
- Replace command dispatch chain with a command registry pattern (map of command name → handler)
- Flatten nested option parsing with a declarative options schema

**higgsfield-video.mjs** (345 complexity, 36 functions):
- Extract video processing stages into pipeline functions
- Replace nested callbacks with async/await chains
- Extract format-specific logic into format handlers

**higgsfield-common.mjs** (298 complexity, 59 functions):
- Extract utility groups: API client, config parsing, output formatting, error handling
- Replace complex binary expressions with named boolean helpers
- Deduplicate any shared patterns across the trio

### Step 3: Shared extraction
- Identify code duplicated across the three files
- Extract into `higgsfield-shared.mjs` or merge into `higgsfield-common.mjs`

## Acceptance Criteria

- [ ] Decision documented: generated/vendored (exclude) vs authored (refactor)
- [ ] If excluded: files added to `.qlty/qlty.toml` `exclude_patterns` with comment explaining why
  ```yaml
  verify:
    method: codebase
    pattern: "higgsfield"
    path: ".qlty/qlty.toml"
  ```
- [ ] If refactored: combined complexity below 300 (from 1049)
  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && ~/.qlty/bin/qlty smells .agents/scripts/higgsfield/ --sarif 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(len(d.get('runs',[])[0].get('results',[])))\""
  ```
- [ ] If refactored: no individual function exceeds complexity 15
- [ ] All higgsfield CLI commands still work (generate, list, status, etc.)
  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/higgsfield/higgsfield-commands.mjs --help 2>&1 || true"
  ```
- [ ] Lint clean

## Context & Decisions

- The triage step is critical — if these are generated/vendored, refactoring is wasted effort
- These three files together are ~5k lines; if they need full refactoring, consider splitting into a `higgsfield/` module with multiple smaller files
- The git log will show whether these files have organic commit history (authored) or were added in bulk (generated/vendored)

## Relevant Files

- `.agents/scripts/higgsfield/higgsfield-commands.mjs` — 2218 lines, complexity 406
- `.agents/scripts/higgsfield/higgsfield-video.mjs` — 1374 lines, complexity 345
- `.agents/scripts/higgsfield/higgsfield-common.mjs` — 1456 lines, complexity 298
- `.qlty/qlty.toml` — add exclusions here if vendored/generated

## Dependencies

- **Blocked by:** nothing
- **Blocks:** overall qlty A-grade recovery (this is the single biggest contributor)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Triage | 15m | Determine authored vs generated/vendored |
| Implementation (if exclude) | 15m | Add qlty exclusion pattern |
| Implementation (if refactor) | 6h | Decompose 143 functions across 3 files |
| Testing | 30m | Qlty before/after, CLI smoke test |
| **Total** | **30m (exclude) or ~7h (refactor)** | |
