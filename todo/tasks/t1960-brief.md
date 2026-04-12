<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1960: Enable 1M context window for Claude models in opencode-aidevops plugin

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (user request)
- **Conversation context:** User noticed models were auto-compacting below 200K tokens despite expecting 1M context. Investigation found the `opencode-aidevops` plugin hardcodes `limit.context: 200000` for all Claude models and does not inject the `context-1m-2025-08-07` beta header on API requests.

## What

Enable the full 1M token context window for all three Claude models (Haiku 4.5, Sonnet 4.6, Opus 4.6) when routed through the `opencode-aidevops` plugin. After this change, OpenCode's auto-compaction threshold should move from ~160K to ~800K (80% of the declared context window), and the Anthropic API should accept input up to 1M tokens.

## Why

OpenCode uses `provider.{name}.models.{id}.limit.context` to decide when to auto-compact sessions (at ~80% of the declared window). The plugin currently declares 200K for all Claude models, causing unnecessary compaction around 160K even though Anthropic now supports 1M context for Haiku, Sonnet, and Opus via the `context-1m-2025-08-07` beta header. This wastes tokens on premature compaction and breaks long-running sessions that legitimately need large context (codebase exploration, multi-file refactors, memory recall across many documents).

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 3 files (`provider-auth.mjs`, `config-hook.mjs`, `claude-proxy.mjs`)
- [x] **Complete code blocks for every edit?** — yes, exact edits below
- [x] **No judgment or design decisions?** — mechanical value swaps
- [x] **No error handling or fallback logic to design?** — existing header merge path handles it
- [x] **Estimate 1h or less?** — ~20min
- [x] **4 or fewer acceptance criteria?** — 4 criteria

One checkbox fails (3 files, not 2), so this is `tier:standard`. However, the changes themselves are mechanical and the risk is low — it's a plugin-wide configuration bump with a single new beta header. Worker-ready.

**Selected tier:** `tier:standard`

**Tier rationale:** 3-file mechanical change with exact edits specified, but touches plugin core + adds a beta header that affects every API call, so the standard tier's verification rigor (worktree, linters, PR review) is appropriate rather than `tier:simple`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/provider-auth.mjs:364-370` — add `context-1m-2025-08-07` to `REQUIRED_BETAS`
- `EDIT: .agents/plugins/opencode-aidevops/config-hook.mjs:34-63` — bump `limit.context` from 200000 to 1000000 in both `ANTHROPIC_MODELS` and `CLAUDECLI_MODELS`; also bump Sonnet output from 32000 to 64000 (stale cap)
- `EDIT: .agents/plugins/opencode-aidevops/claude-proxy.mjs:302-326` — sync `getClaudeProxyModels()` drift copy to match config-hook values (keeps the two lists in sync until a future refactor removes one)

### Implementation Steps

1. **Add the beta header** in `provider-auth.mjs`:

```javascript
const REQUIRED_BETAS = [
  "oauth-2025-04-20",
  "interleaved-thinking-2025-05-14",
  "context-management-2025-06-27",
  "context-1m-2025-08-07",
  "prompt-caching-scope-2026-01-05",
  "claude-code-20250219",
];
```

The existing `mergeBetaHeaders()` at `provider-auth.mjs:825-850` will automatically include this new entry on every outgoing request.

2. **Bump context window** in `config-hook.mjs` — both `ANTHROPIC_MODELS` (lines 34-47) and `CLAUDECLI_MODELS` (lines 50-63):

```javascript
const ANTHROPIC_MODELS = {
  "claude-haiku-4-5": claudeModelDef({
    name: "Claude Haiku 4.5 (via aidevops)",
    limit: { context: 1000000, output: 32000 },
  }),
  "claude-sonnet-4-6": claudeModelDef({
    name: "Claude Sonnet 4.6 (via aidevops)",
    limit: { context: 1000000, output: 64000 },
  }),
  "claude-opus-4-6": claudeModelDef({
    name: "Claude Opus 4.6 (via aidevops)",
    limit: { context: 1000000, output: 64000 },
  }),
};
```

Apply the same changes to `CLAUDECLI_MODELS` (just the `(via CLI)` name variant).

3. **Sync drift copy** in `claude-proxy.mjs` `getClaudeProxyModels()`:

```javascript
return [
  { id: "claude-haiku-4-5",  name: "Claude Haiku 4.5 (via Claude CLI)",  reasoning: true, contextWindow: 1000000, maxTokens: 32000 },
  { id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6 (via Claude CLI)", reasoning: true, contextWindow: 1000000, maxTokens: 64000 },
  { id: "claude-opus-4-6",   name: "Claude Opus 4.6 (via Claude CLI)",   reasoning: true, contextWindow: 1000000, maxTokens: 32000 },
];
```

### Verification

```bash
# 1. Lint/shellcheck passes (no JS linter in this repo; lint script handles it)
.agents/scripts/linters-local.sh

# 2. Confirm the beta header is in the required list
grep -c "context-1m-2025-08-07" .agents/plugins/opencode-aidevops/provider-auth.mjs  # should output 1

# 3. Confirm no 200000 context values remain in model definitions
grep -n "context: 200000" .agents/plugins/opencode-aidevops/config-hook.mjs  # should output nothing
grep -n "contextWindow: 200000" .agents/plugins/opencode-aidevops/claude-proxy.mjs  # should output nothing

# 4. Confirm all three models show 1000000
grep -c "context: 1000000" .agents/plugins/opencode-aidevops/config-hook.mjs  # should output 6 (3 models x 2 providers)
```

## Acceptance Criteria

- [ ] `context-1m-2025-08-07` appears in `REQUIRED_BETAS` in `provider-auth.mjs`
  ```yaml
  verify:
    method: codebase
    pattern: "context-1m-2025-08-07"
    path: ".agents/plugins/opencode-aidevops/provider-auth.mjs"
  ```
- [ ] No `context: 200000` in `config-hook.mjs` model definitions
  ```yaml
  verify:
    method: codebase
    pattern: "context: 200000"
    path: ".agents/plugins/opencode-aidevops/config-hook.mjs"
    expect: absent
  ```
- [ ] All three models declare `context: 1000000` in both `ANTHROPIC_MODELS` and `CLAUDECLI_MODELS` (6 occurrences total)
  ```yaml
  verify:
    method: bash
    run: "test $(grep -c 'context: 1000000' .agents/plugins/opencode-aidevops/config-hook.mjs) -eq 6"
  ```
- [ ] Lint clean: `.agents/scripts/linters-local.sh` exits 0
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh"
  ```

## Context & Decisions

- **Why 1M header alone is sufficient:** Anthropic's `context-1m-2025-08-07` beta gates context above 200K for all currently-supported Claude 4.x models (Haiku, Sonnet, Opus) — a single header change covers all three.
- **Pricing awareness:** Above 200K input tokens, requests shift to the higher 1M tier (~2x input, ~1.5x output). Absorbed by OAuth subscription accounts; a real cost on pay-as-you-go API keys. The plugin already sets `cost: { input: 0, output: 0, ... }` so OpenCode UI cost estimates aren't affected by this change.
- **Sonnet output bump:** Current config declares `output: 32000` for Sonnet, but Sonnet 4.x supports 64K output. Fixing while we're in the file to avoid a follow-up PR.
- **Drift copy:** `claude-proxy.mjs:302-326` `getClaudeProxyModels()` duplicates the model list but appears unused — `config-hook.mjs` has its own authoritative `CLAUDECLI_MODELS`. Syncing the drift copy rather than deleting it to keep the change minimal; a future refactor can remove the duplication.
- **Non-goal:** Runtime testing of actual 1M requests. This is a config change; end-to-end verification requires an OpenCode session restart and a real long-context workload, which is user-driven after deployment.

## Relevant Files

- `.agents/plugins/opencode-aidevops/provider-auth.mjs:364` — `REQUIRED_BETAS` list
- `.agents/plugins/opencode-aidevops/provider-auth.mjs:825-850` — `mergeBetaHeaders()` (no changes needed; automatically picks up new entries)
- `.agents/plugins/opencode-aidevops/config-hook.mjs:34-63` — `ANTHROPIC_MODELS` / `CLAUDECLI_MODELS`
- `.agents/plugins/opencode-aidevops/claude-proxy.mjs:302-326` — `getClaudeProxyModels()` drift copy

## Dependencies

- **Blocked by:** none
- **Blocks:** longer autonomous sessions without premature auto-compaction
- **External:** OAuth pool accounts must have 1M beta access (rolled out with the `context-1m-2025-08-07` header for Sonnet first; Haiku/Opus added subsequently per user confirmation)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Already done in interactive session |
| Implementation | 10m | 3 mechanical edits |
| Testing | 10m | linters-local.sh + grep verification |
| **Total** | **30m** | |
