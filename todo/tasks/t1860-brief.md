---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1860: simplification: reduce function complexity in oauth-pool.mjs

## Origin

- **Created:** 2026-04-03
- **Session:** opencode:qlty-maintainability-recovery
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability grade dropped from A to C. `oauth-pool.mjs` has the highest total file complexity (440) with 96 functions, 12 of which exceed the complexity threshold (worst at 53). It is the single largest contributor to the qlty smell count.

## What

Reduce total file complexity of `.agents/plugins/opencode-aidevops/oauth-pool.mjs` (3229 lines) from 440 to under 120 by decomposing the 12 high-complexity functions into smaller units. Each function should have complexity under 15 after refactoring. The file's exported API must remain unchanged.

## Why

- Highest total file complexity in the codebase (440 points)
- 12 functions individually exceed qlty's complexity threshold
- Accounts for ~33% of all code smells in the repo
- Combined with t1858 (provider-auth.mjs), these two files represent ~53% of total smell load

## How (Approach)

### Phase 1: Audit (identify the 12 hot functions)
1. Run `qlty smells .agents/plugins/opencode-aidevops/oauth-pool.mjs --sarif` to get precise function names and line ranges
2. Rank by complexity score — tackle highest first

### Phase 2: Structural decomposition patterns
For each high-complexity function, apply the appropriate pattern:
- **Long switch/if-else chains** → extract to lookup table or strategy map
- **Deeply nested callbacks/promises** → extract named async functions
- **Functions with many returns** (6-21 reported) → restructure with early-return guard clauses
- **Mixed concerns** (validation + business logic + error handling) → separate into validate/execute/handleError layers

### Phase 3: File organization
- Group extracted helpers near their callers or into logical sections
- Consider splitting into `oauth-pool-providers.mjs`, `oauth-pool-rotation.mjs`, `oauth-pool-utils.mjs` if the file remains over 2000 lines after refactoring — but only if natural seams exist
- Re-export from `oauth-pool.mjs` to preserve the public API

### Phase 4: Verify
- Run qlty smells before/after
- Ensure all provider rotation, cooldown, LRU, and 429 failover logic still works

Key files:
- `.agents/plugins/opencode-aidevops/oauth-pool.mjs` — target (3229 lines, 96 functions, 12 high-complexity)
- `.agents/plugins/opencode-aidevops/provider-auth.mjs` — tightly coupled, imports from oauth-pool
- `.agents/plugins/opencode-aidevops/index.mjs` — plugin entry point

## Acceptance Criteria

- [ ] Total file complexity drops below 120 (from 440)
  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && ~/.qlty/bin/qlty smells .agents/plugins/opencode-aidevops/oauth-pool.mjs --sarif 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); runs=d.get('runs',[]); total=[r for run in runs for r in run.get('results',[]) if 'total complexity' in r.get('message',{}).get('text','').lower()]; sys.exit(0 if not total or int(''.join(filter(str.isdigit, total[0]['message']['text'].split('complexity')[1][:5]))) < 120 else 1)\""
  ```
- [ ] No individual function exceeds complexity 15
- [ ] Zero "deeply nested control flow" smells remain
- [ ] Functions with many returns reduced to max 4 returns each
- [ ] All exported functions maintain identical signatures
  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && grep -c 'export' .agents/plugins/opencode-aidevops/oauth-pool.mjs"
  ```
- [ ] OAuth pool rotation still works (LRU selection, 429 failover, cooldown tracking)
  ```yaml
  verify:
    method: manual
    prompt: "Run a session that triggers provider rotation and verify accounts are selected and rotated correctly"
  ```
- [ ] Lint clean

## Context & Decisions

- This is a pure refactoring task — no feature changes
- File may benefit from splitting into 2-3 modules if natural seams exist, but this is optional — complexity reduction is the goal
- The 96 function count is not itself a problem — many small functions is better than few large ones
- Priority order: tackle the complexity-53 function first, then work down the list

## Relevant Files

- `.agents/plugins/opencode-aidevops/oauth-pool.mjs:1` — target file (3229 lines)
- `.agents/plugins/opencode-aidevops/provider-auth.mjs` — coupled; refactored in t1858
- `.agents/plugins/opencode-aidevops/index.mjs` — plugin entry, wires pool

## Dependencies

- **Blocked by:** nothing (can run in parallel with t1858, but sequencing after t1858 avoids merge conflicts in shared imports)
- **Blocks:** overall qlty A-grade recovery
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Audit 12 hot functions, map dependencies |
| Implementation | 4h | Decompose 12 functions, flatten nesting, extract utilities |
| Testing | 1h | Qlty before/after, manual rotation test |
| **Total** | **~5.5h** | |
