---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1914: Decompose opencode-aidevops plugin directory (architectural refactor)

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:qlty-maintainability-a-grade
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability badge dropped to C. 15 of 45 files with smells are in `.agents/plugins/opencode-aidevops/`, accounting for ~1,300 combined Qlty complexity. The plugin was written as a monolith with tightly coupled modules. Individual file simplification tasks (t1858, t1860) address the worst offenders, but the directory needs architectural decomposition to bring all files under threshold.

## What

Map the dependency graph within `.agents/plugins/opencode-aidevops/`, identify natural module boundaries, and decompose the plugin into well-defined modules that each stay under Qlty's complexity thresholds. The plugin's external API (exported functions used by opencode) must remain unchanged. Internal wiring may change freely.

## Why

- 15 files contribute ~1,300 combined Qlty complexity from a single directory
- The plugin is the densest concentration of smells in the codebase
- Individual file tasks (t1858, t1860) reduce the worst peaks but don't address architectural coupling
- Functions in `index.mjs` (complexity 223), `proxy.js` (171), `google-proxy.mjs` (70), `agent-loader.mjs` (66), `observability.mjs` (per-file smells) are interdependent — splitting them requires understanding the whole plugin

### Current Qlty smell distribution in this directory

| File | Complexity | Key smells |
|------|-----------|------------|
| `oauth-pool.mjs` | 440 | 12 high-complexity functions (t1860 in progress) |
| `provider-auth.mjs` | 334 | High total complexity (t1858 partially resolved) |
| `index.mjs` | 223 | 7-return function, high total complexity |
| `proxy.js` | 171 | 21-complexity function, 7-return function, high total |
| `google-proxy.mjs` | 70 | 29-complexity function, 10-return function |
| `agent-loader.mjs` | 66 | High total complexity |
| `observability.mjs` | ~50 | Multiple smells |
| `ttsr.mjs` | ~30 | Multiple smells |

## Tier

`tier:reasoning`

**Tier rationale:** Architectural decomposition of a tightly coupled monolithic plugin. Requires mapping the dependency graph across 15 files, identifying natural module boundaries, and designing a decomposition that preserves the external API while restructuring internal wiring. This is novel design work with no existing pattern to follow — the plugin is unique in the codebase.

## How (Approach)

### Phase 1: Dependency Graph Mapping

1. Map all `import`/`export` relationships between the 15 files
2. Identify which functions are called cross-file vs internal-only
3. Map the plugin's external API (what `opencode` imports from this directory)
4. Identify circular dependencies that constrain decomposition options

### Phase 2: Module Boundary Design

Based on the dependency graph, propose module boundaries along these candidate seams:

- **Auth module** — `provider-auth.mjs`, `oauth-pool.mjs`, `oauth-pool-lib/` → auth strategy, token management, pool rotation
- **Proxy module** — `proxy.js`, `google-proxy.mjs` → protocol translation, request routing
- **Core module** — `index.mjs`, `agent-loader.mjs` → plugin lifecycle, hook registration
- **Observability module** — `observability.mjs`, `ttsr.mjs` → telemetry, tracing
- **Cursor module** — `cursor/` directory → Cursor-specific protocol handling

### Phase 3: Incremental Decomposition

For each module boundary:
1. Extract shared types/interfaces into a `types.mjs` or per-module type file
2. Move functions to their new module
3. Update internal imports
4. Verify external API unchanged
5. Run `qlty smells` on each module file — target: no file over complexity 50

### Phase 4: Verify

- `qlty smells --all` on the plugin directory shows zero files above complexity threshold
- Plugin still loads and functions in opencode
- All existing test patterns still pass

### Files to Analyze

- `.agents/plugins/opencode-aidevops/index.mjs` — plugin entry point (1406 lines)
- `.agents/plugins/opencode-aidevops/oauth-pool.mjs` — OAuth pool management (3229 lines)
- `.agents/plugins/opencode-aidevops/provider-auth.mjs` — auth hook (1155 lines)
- `.agents/plugins/opencode-aidevops/cursor/proxy.js` — Cursor proxy (1245 lines)
- `.agents/plugins/opencode-aidevops/google-proxy.mjs` — Google proxy (535 lines)
- `.agents/plugins/opencode-aidevops/agent-loader.mjs` — agent config loader
- `.agents/plugins/opencode-aidevops/observability.mjs` — telemetry (750 lines)
- `.agents/plugins/opencode-aidevops/ttsr.mjs` — TTSR handler

### Verification

```bash
# All plugin files under complexity 50
~/.qlty/bin/qlty smells --all 2>&1 | grep 'plugins/opencode-aidevops' | grep -v 'High total complexity'

# Plugin loads successfully
# (manual: start opencode session, verify plugin initialises)

# No regression in external API
grep -r 'export' .agents/plugins/opencode-aidevops/index.mjs | wc -l
```

## Acceptance Criteria

- [ ] Dependency graph documented (which files import what from where)
- [ ] Module boundaries defined with rationale
- [ ] No individual file in the plugin directory exceeds Qlty complexity 50
  ```yaml
  verify:
    method: bash
    run: "~/.qlty/bin/qlty smells --all 2>&1 | grep 'plugins/opencode-aidevops' | grep -c 'High total complexity' | grep -q '^0$' && echo PASS || echo FAIL"
  ```
- [ ] External API unchanged — `index.mjs` exports identical set of functions
- [ ] Plugin loads and initialises in opencode without errors
  ```yaml
  verify:
    method: manual
    prompt: "Start an opencode session and verify the aidevops plugin loads (check for 'aidevops plugin loaded' in logs)"
  ```
- [ ] Internal imports use the new module structure (no circular dependencies)
- [ ] `qlty smells --all` shows fewer than 5 smells in the plugin directory (from current ~15 files × multiple smells each)

## Context & Decisions

- This is a coordinating task — it may spawn subtasks for individual module extractions
- Depends on t1860 (oauth-pool.mjs) completing first to avoid merge conflicts
- t1858 (provider-auth.mjs) was partially resolved — this task should complete the remaining smells
- The `cursor/` subdirectory is already somewhat modular — it may need less work
- The plugin has no test suite — manual verification (plugin loads, auth works) is the primary safety net
- Prefer moving functions between files over creating new abstraction layers — the goal is complexity reduction, not architecture astronautics

## Relevant Files

- `.agents/plugins/opencode-aidevops/` — entire plugin directory (15 files)
- `.agents/plugins/opencode-aidevops/index.mjs:1` — plugin entry (1406 lines, complexity 223)
- `.agents/plugins/opencode-aidevops/oauth-pool.mjs:1` — pool manager (3229 lines, complexity 440)
- `.agents/plugins/opencode-aidevops/provider-auth.mjs:1` — auth hook (1155 lines, complexity 334)
- `.agents/plugins/opencode-aidevops/cursor/proxy.js:1` — Cursor proxy (1245 lines, complexity 171)

## Dependencies

- **Blocked by:** t1860 (oauth-pool.mjs simplification should merge first to avoid conflicts)
- **Blocks:** sustained A-grade maintainability (this directory is ~50% of total smell count)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Map dependency graph across 15 files |
| Design | 1h | Define module boundaries, document rationale |
| Implementation | 4h | Extract modules, rewire imports |
| Testing | 1h | Qlty verification, manual plugin load test |
| **Total** | **~7h** | |
