<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2070: Decompose `.agents/plugins/opencode-aidevops/claude-proxy.mjs` (6 qlty smells)

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** 4th-highest smell file in the repo. Hosts the opencode ↔ Claude API streaming proxy — including `tryStreamWithAccount` (cyclomatic 38) and `processStreamEvent` (cyclomatic 34). Both are async stream handlers with branching on event type × account state × error category.

## What

Decompose `claude-proxy.mjs` so no function exceeds cyclomatic 15, keeping the streaming behaviour byte-identical. After this change, `qlty smells` reports zero smells on `claude-proxy.mjs`.

## Why

- `tryStreamWithAccount` and `processStreamEvent` together carry the lion's share of the file's complexity. Both are on the hot path for every opencode request to Claude — correctness matters, and correctness is inspectable only if complexity is low enough to hold in head.
- 6 smells removed = ~5.5% progress toward A.
- This file has already received CodeRabbit-driven cleanup rounds (see GH#18621) — the structural refactor is the missing piece.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Async streaming with SSE event handling, per-account retry, and provider-specific error mapping. Very easy to introduce subtle bugs that only show up under load. Opus-tier.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Smell breakdown for this file
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq -r '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == ".agents/plugins/opencode-aidevops/claude-proxy.mjs") | "\(.ruleId)\t\(.message.text)\t\(.locations[0].physicalLocation.region.startLine)"'

# 2. Key targets
rg -n "processStreamEvent|tryStreamWithAccount" .agents/plugins/opencode-aidevops/claude-proxy.mjs

# 3. Related test/integration harness
ls .agents/plugins/opencode-aidevops/test* 2>/dev/null
rg -l "claude-proxy" .agents/plugins/opencode-aidevops/
```

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/claude-proxy.mjs` — primary target
- `NEW: .agents/plugins/opencode-aidevops/claude-proxy-stream.mjs` — extracted stream processing (processStreamEvent + event-type handlers)
- `NEW: .agents/plugins/opencode-aidevops/claude-proxy-retry.mjs` — extracted account retry logic (tryStreamWithAccount helpers)
- `EDIT: any tests/integration harness` — verify still pass

### Implementation Steps

1. **Extract event-type handlers.** `processStreamEvent` branches on SSE event type (`message_start`, `content_block_delta`, `tool_use_delta`, etc.). Pull each branch into a dedicated handler:

   ```javascript
   // claude-proxy-stream.mjs
   export const STREAM_HANDLERS = {
     message_start: (event, state) => { ... },
     content_block_start: (event, state) => { ... },
     content_block_delta: (event, state) => { ... },
     tool_use_delta: (event, state) => { ... },
     // ...
   };

   export function processStreamEvent(event, state) {
     const handler = STREAM_HANDLERS[event.type];
     if (!handler) return state;
     return handler(event, state);
   }
   ```

   Target: dispatcher cyclomatic ≤ 5, each handler ≤ 10.

2. **Extract retry logic from `tryStreamWithAccount`.** The function likely looks like:

   ```
   for each account:
     try stream
     on 401 → mark revoked → next account
     on 429 → cooldown → next account
     on 5xx → retry same account with backoff
     on success → return
   ```

   Extract each error-category handler:

   ```javascript
   // claude-proxy-retry.mjs
   export async function handle401(account, pool) { /* mark + next */ }
   export async function handle429(account, pool) { /* cooldown + next */ }
   export async function handle5xx(account, pool, attempt) { /* backoff + retry */ }

   export async function tryStreamWithAccount(account, pool, request) {
     try {
       return await streamOnce(account, request);
     } catch (e) {
       if (e.status === 401) return handle401(account, pool);
       if (e.status === 429) return handle429(account, pool);
       if (e.status >= 500)  return handle5xx(account, pool, 1);
       throw e;
     }
   }
   ```

   Target: dispatcher cyclomatic ≤ 8, each handler ≤ 10.

3. **Preserve behaviour.** Before touching the code, add a characterisation test that exercises at least: successful stream, 401 fallover, 429 cooldown, 5xx retry, tool-use event, message-delta event. Run against pre-refactor code to confirm green, then refactor, then re-run.

4. **Clean up `claude-proxy.mjs`** to import from the new modules. Keep the public `createClaudeProxy()` surface unchanged.

### Verification

```bash
# Zero smells
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("claude-proxy"))] | length'

# Lints clean
cd .agents/plugins/opencode-aidevops && bun run lint 2>&1 || echo "no lint"

# Smoke test
cd .agents/plugins/opencode-aidevops && bun test 2>&1 || echo "no tests"
```

## Acceptance Criteria

- [ ] `qlty smells` reports **zero** smells on `claude-proxy.mjs` and any extracted modules
- [ ] `processStreamEvent` cyclomatic ≤ 10, `tryStreamWithAccount` cyclomatic ≤ 10
- [ ] Existing opencode-aidevops tests pass (`bun test` in the plugin dir)
- [ ] Public surface (`createClaudeProxy`, exported hooks) unchanged
- [ ] Repo-wide total smell count drops by at least 5

## Context & Decisions

- **Do not change the SSE wire protocol handling** — it's locked to Claude's current API. Refactor structure, preserve semantics.
- **Stream back-pressure must be preserved** — if the current code uses specific flush/await patterns, replicate them exactly in the extracted handlers.
- GH#18621 already did CodeRabbit-driven cleanup on this file. Read that PR's diff first to avoid undoing the model-table + abort-cleanup work.

## Relevant Files

- `.agents/plugins/opencode-aidevops/claude-proxy.mjs` — primary target
- `.agents/plugins/opencode-aidevops/provider-auth.mjs` — sibling; may share helpers for account state
- `.agents/plugins/opencode-aidevops/oauth-pool.mjs` — likely the account pool abstraction

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Full file + GH#18621 diff + related plugins |
| Characterisation tests | 1.5h | Pin SSE + retry behaviour |
| Implementation | 3h | Extract + facade |
| Testing | 1h | Rerun tests + manual smoke |
| **Total** | **~6.5h** | |
