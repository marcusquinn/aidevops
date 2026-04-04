---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1858: simplification: reduce function complexity in provider-auth.mjs

## Origin

- **Created:** 2026-04-03
- **Session:** opencode:qlty-maintainability-recovery
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability grade dropped from A to C. `provider-auth.mjs` contains a single function `createProviderAuthHook` with complexity 252, making it the highest-density smell in the codebase. Decomposing this one function is the single highest-impact change for grade recovery.

## What

Decompose `createProviderAuthHook` in `.agents/plugins/opencode-aidevops/provider-auth.mjs` (811 lines) from a single monolithic function (complexity 252) into smaller, composed helper functions, each with complexity under 15. The file's external API (exported function signature and behaviour) must remain unchanged.

## Why

- Qlty maintainability dropped from A to C; this file accounts for 255 of 131 total smell points
- Single function with complexity 252 is the densest smell in the entire codebase
- Decomposing it removes ~19% of total codebase complexity in one task
- Highest ROI simplification target — one file, one function, massive impact

## How (Approach)

1. **Read the full function** to understand the control flow branches (provider dispatch, token refresh, error handling, retry logic, cooldown management)
2. **Identify logical segments** within the function — each `if/else` branch handling a different provider (anthropic, openai, cursor, google) is a candidate for extraction
3. **Extract provider-specific handlers** into named functions: `handleAnthropicAuth()`, `handleOpenAIAuth()`, `handleCursorAuth()`, `handleGoogleAuth()`
4. **Extract cross-cutting concerns** into utilities: `refreshToken()`, `handleCooldown()`, `selectAccount()`, `validateCredentials()`
5. **Replace deeply nested control flow** with early returns and guard clauses
6. **Reassemble `createProviderAuthHook`** as a thin orchestrator that dispatches to the extracted functions
7. **Preserve all existing behaviour** — no functional changes, pure refactor

Key files:
- `.agents/plugins/opencode-aidevops/provider-auth.mjs` — the target (811 lines)
- `.agents/plugins/opencode-aidevops/oauth-pool.mjs` — related, imports from this file; ensure no API breakage
- `.agents/plugins/opencode-aidevops/index.mjs` — plugin entry point that wires the auth hook

## Acceptance Criteria

- [ ] `createProviderAuthHook` function complexity drops below 20 (from 252)
  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && ~/.qlty/bin/qlty smells .agents/plugins/opencode-aidevops/provider-auth.mjs --sarif 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); results=[r for r in d.get('runs',[])[0].get('results',[]) if 'high complexity' in r.get('message',{}).get('text','').lower()]; sys.exit(0 if all(int(''.join(filter(str.isdigit, r['message']['text'].split('complexity')[1][:5]))) < 20 for r in results if 'complexity' in r['message']['text']) else 1)\""
  ```
- [ ] No individual function in the file exceeds complexity 15
- [ ] Total file complexity drops below 80 (from 255)
- [ ] All existing provider auth flows still work (anthropic, openai, cursor, google)
  ```yaml
  verify:
    method: manual
    prompt: "Test OAuth pool rotation with at least one provider to confirm auth hook still works"
  ```
- [ ] No changes to the exported function signature — `createProviderAuthHook` still accepts and returns the same types
  ```yaml
  verify:
    method: codebase
    pattern: "export.*createProviderAuthHook"
    path: ".agents/plugins/opencode-aidevops/provider-auth.mjs"
  ```
- [ ] Lint clean (no new eslint/qlty warnings introduced)

## Context & Decisions

- This is a pure refactoring task — no feature changes
- The function is likely a large switch/if-else dispatching per provider; strategy pattern extraction is the standard approach
- Must not break the plugin's integration with opencode — the auth hook is called on every API request
- Deeply nested control flow (5+ levels reported by qlty) should flatten to max 3 levels

## Relevant Files

- `.agents/plugins/opencode-aidevops/provider-auth.mjs` — target file (811 lines, complexity 252)
- `.agents/plugins/opencode-aidevops/oauth-pool.mjs` — imports from provider-auth; check for coupling
- `.agents/plugins/opencode-aidevops/index.mjs` — wires the hook; verify integration unchanged

## Dependencies

- **Blocked by:** nothing
- **Blocks:** overall qlty A-grade recovery
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Read full function, map control flow |
| Implementation | 2h | Extract 6-8 helper functions, flatten nesting |
| Testing | 30m | Verify qlty smells reduced, manual auth test |
| **Total** | **~3h** | |
