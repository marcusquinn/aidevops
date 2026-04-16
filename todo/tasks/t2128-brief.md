---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2128: refactor(opencode-aidevops) — decompose oauth-pool plugin cluster

## Origin

- **Created:** 2026-04-16
- **Session:** Claude:interactive
- **Created by:** ai-interactive (maintainer directed)
- **Parent task:** t2126 (#19222)
- **Conversation context:** Child of the qlty A-grade campaign. The oauth-pool plugin was partially decomposed in PR #18906 (t2071), which extracted `cursor/proxy.js`, `ttsr.mjs`, `provider-auth.mjs`, `google-proxy.mjs` from the opencode-aidevops cluster. However, the 3 `oauth-pool*.mjs` files remain at file-complexity levels that qlty flags.

## What

Clear the 3 remaining `qlty:file-complexity` smells in `.agents/plugins/opencode-aidevops/`:

| File | Lines | Complexity | Target |
|------|-------|-----------|--------|
| `oauth-pool-auth.mjs` | 312 | **121** | ≤ file_complexity default |
| `oauth-pool.mjs` | 1220 | **117** | ≤ file_complexity default |
| `oauth-pool-tool.mjs` | ~350 | **72** | ≤ file_complexity default |

**Total current complexity: 310.** Each file needs further extraction so `qlty smells --all` no longer reports file-complexity on them.

Deliverable:

1. Decomposed modules, each under the file_complexity threshold (~60).
2. No circular dependencies introduced (the current `oauth-pool-auth.mjs` already documents "duplicated to avoid circular dependency" — must preserve or improve this).
3. The OpenCode plugin loader (`oauth-pool.mjs` default export as auth hook provider) continues to function — test via the existing `node --check` and import resolution.
4. `oauth-pool-helper.sh` CLI commands work unchanged.

## Why

These 3 files contribute 3 of the 20 remaining smells. Combined with the 4 higgsfield smells (t2127), clearing them takes us from 20 → 13, well inside grade-A territory. The oauth-pool module is also the most frequently patched plugin cluster (4 PRs in the last 7 days: #19174, #19164, #19162, #19149), so reducing per-file complexity here has a direct ROI on future maintainability.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? **NO — 3 files to split, plus new modules**
- [ ] Every target file under 500 lines? **YES for auth and tool (312/350), NO for pool (1220)**
- [ ] Exact `oldString`/`newString` for every edit? **NO — module boundary is a design decision**
- [ ] No judgment or design decisions? **NO — must resolve circular dependency concern**
- [ ] No error handling or fallback logic to design? **YES — existing error logic preserved as-is**
- [ ] No cross-package changes? **Single plugin directory**
- [ ] Estimate 1h or less? **NO — 2h**
- [ ] 4 or fewer acceptance criteria? **NO — 5**

**Selected tier:** `tier:thinking`

**Tier rationale:** The oauth-pool module has an explicitly documented circular dependency concern (`oauth-pool-auth.mjs` duplicates constants from `oauth-pool.mjs` to avoid a cycle). Decomposition must either keep this pattern or introduce a constants module — both require understanding the full import graph, which is judgment work.

## PR Conventions

PR body: `For #19222` (parent) and `Resolves #19224` (this task's issue).

## How (Approach)

### Worker Quick-Start

```bash
# 1. Understand the existing structure and circular dependency note:
head -35 .agents/plugins/opencode-aidevops/oauth-pool-auth.mjs
# Note the "duplicated from main module to avoid circular dependency" comment

# 2. See the full import graph — who imports what from oauth-pool.mjs:
rg "from.*oauth-pool" .agents/plugins/opencode-aidevops/ --no-heading
# This maps the dependency edges

# 3. Baseline smell counts:
qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | contains("oauth-pool")) | "\(.locations[0].physicalLocation.artifactLocation.uri)\t\(.message.text)"'

# 4. Reference pattern — how claude-proxy was decomposed (6 sibling modules):
ls .agents/scripts/claude-proxy/
```

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/oauth-pool.mjs` (1220 lines, complexity 117) — the core module. Extract into:
  - `NEW: .agents/plugins/opencode-aidevops/oauth-pool-constants.mjs` — shared constants, user agents, URLs (resolves the circular dep)
  - `NEW: .agents/plugins/opencode-aidevops/oauth-pool-storage.mjs` — pool file I/O: `loadPool`, `savePool`, `withPoolLock`, `getPoolFilePath`, `getAccounts`, `upsertAccount`, `removeAccount`, `patchAccount`
  - `NEW: .agents/plugins/opencode-aidevops/oauth-pool-rotation.mjs` — the 429 rotation fetch wrapper, cooldown tracking, `resolveInjectFn`, injection functions
  - Keep `oauth-pool.mjs` as the entry re-exporting the public surface (for backward compat with the 18 imports scattered across the plugin)
- `EDIT: .agents/plugins/opencode-aidevops/oauth-pool-auth.mjs` (312 lines, complexity 121) — split provider-specific OAuth flows into:
  - `NEW: .agents/plugins/opencode-aidevops/oauth-pool-auth-anthropic.mjs` — Anthropic OAuth flow
  - `NEW: .agents/plugins/opencode-aidevops/oauth-pool-auth-openai.mjs` — OpenAI OAuth flow
  - Keep remaining (Google, Cursor, PKCE common, callback server) in `oauth-pool-auth.mjs` if that gets it under threshold; else split further
- `EDIT: .agents/plugins/opencode-aidevops/oauth-pool-tool.mjs` (~350 lines, complexity 72) — extract action handlers:
  - `NEW: .agents/plugins/opencode-aidevops/oauth-pool-actions.mjs` — the per-action handlers (`list`, `rotate`, `remove`, `assign-pending`, `check`, `status`, `reset-cooldowns`, `set-priority`). Keep `createPoolTool` in `oauth-pool-tool.mjs` as the dispatcher.

### Implementation Steps

1. **Read all 3 files + map the import graph.** There are ~18 import statements from other files in the plugin directory pointing to `oauth-pool.mjs`. These must all continue to resolve after the split. A re-export barrel in `oauth-pool.mjs` is the simplest way to keep backward compat.
2. **Create `oauth-pool-constants.mjs` first.** This eliminates the circular dependency by giving both `oauth-pool.mjs` and `oauth-pool-auth.mjs` a shared constants module to import from. Move all shared constants there.
3. **Extract `oauth-pool-storage.mjs` from `oauth-pool.mjs`.** File I/O and lock logic.
4. **Extract `oauth-pool-rotation.mjs` from `oauth-pool.mjs`.** The fetch wrapper, cooldown tracking, injection functions.
5. **Trim `oauth-pool.mjs` to a barrel re-export.** It should re-export everything from storage, rotation, and constants so existing `from "./oauth-pool.mjs"` imports work unchanged.
6. **Split provider OAuth flows out of `oauth-pool-auth.mjs`.** One file per provider if needed.
7. **Split action handlers out of `oauth-pool-tool.mjs`.** Move per-action logic to `oauth-pool-actions.mjs`.
8. **Verify: `node --check` on all new .mjs files, run `qlty smells --all` to confirm 0 smells.**

### Verification

```bash
# 1. Parse check on all oauth-pool*.mjs files:
for f in .agents/plugins/opencode-aidevops/oauth-pool*.mjs; do node --check "$f" && echo "OK: $f" || echo "FAIL: $f"; done

# 2. Import resolution (the main module must still be importable):
node -e "import('./agents/plugins/opencode-aidevops/oauth-pool.mjs').then(() => console.log('OK')).catch(e => { console.error(e); process.exit(1); })"

# 3. Zero qlty file-complexity smells on oauth-pool files:
qlty smells --all --sarif 2>/dev/null | \
  jq -r '.runs[0].results[] | select(.ruleId == "qlty:file-complexity") | .locations[0].physicalLocation.artifactLocation.uri' | \
  grep -c 'oauth-pool'
# Expected: 0

# 4. Shell helper still works:
oauth-pool-helper.sh status 2>&1 | head -5
```

## Acceptance Criteria

- [ ] Zero `qlty:file-complexity` smells on any `oauth-pool*.mjs` file
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.ruleId == \"qlty:file-complexity\") | .locations[0].physicalLocation.artifactLocation.uri' | grep -c 'oauth-pool') -eq 0"
  ```
- [ ] `node --check` passes for every `oauth-pool*.mjs` file (original + new)
  ```yaml
  verify:
    method: bash
    run: "for f in .agents/plugins/opencode-aidevops/oauth-pool*.mjs; do node --check \"$f\" || exit 1; done"
  ```
- [ ] No circular dependency warnings at import time (i.e., the constants extraction resolved the existing duplication)
- [ ] Existing `from "./oauth-pool.mjs"` imports throughout the plugin directory still resolve (barrel re-export)
  ```yaml
  verify:
    method: bash
    run: "rg 'from.*oauth-pool\\.mjs' .agents/plugins/opencode-aidevops/ -l | while read f; do node --check \"$f\" || exit 1; done"
  ```
- [ ] No new smells introduced on the new sibling modules
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri' | grep -c 'oauth-pool') -eq 0"
  ```

## Context & Decisions

- **Barrel re-export pattern:** The prior decomposition (t2071, PR #18906) used barrel re-exports in `index.mjs` for the opencode-aidevops plugin. `oauth-pool.mjs` should follow the same pattern — keep it as the public entry that re-exports from the new modules.
- **Circular dependency resolution:** `oauth-pool-auth.mjs` currently duplicates constants to avoid a cycle. The `oauth-pool-constants.mjs` extraction is the clean fix — both modules import constants from a third module. This is a minor improvement, not refactoring scope creep.
- **Non-goal:** changing the 429 rotation logic, the pool file format, or the tool surface. Mechanical extraction only.
- **Prior art:** PR #18893 (claude-proxy → 6 modules), PR #18906 (opencode-aidevops cluster), PR #18860 (oauth-pool namespace fix).

## Relevant Files

- `.agents/plugins/opencode-aidevops/oauth-pool.mjs:1` — core module (1220 lines)
- `.agents/plugins/opencode-aidevops/oauth-pool-auth.mjs:1` — auth hooks (312 lines)
- `.agents/plugins/opencode-aidevops/oauth-pool-tool.mjs:1` — MCP tool (350 lines)
- `.agents/scripts/claude-proxy/` — reference decomposition pattern (6 sibling modules)
- `.agents/scripts/oauth-pool-helper.sh` — shell CLI wrapper that calls into the pool

## Dependencies

- **Blocked by:** none
- **Blocks:** parent t2126 (#19222) closure
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read all 3 files + import graph | 20m | ~1900 lines total |
| Constants extraction | 15m | resolves circular dep |
| Storage extraction | 20m | — |
| Rotation extraction | 20m | — |
| Auth provider split | 20m | — |
| Tool action split | 15m | — |
| Verification + iteration | 20m | — |
| **Total** | **~2.5h** | |
