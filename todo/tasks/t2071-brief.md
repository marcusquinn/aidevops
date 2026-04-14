<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2071: Decompose opencode plugin complexity cluster (cursor/proxy.js, ttsr.mjs, provider-auth.mjs, google-proxy.mjs)

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** After `claude-proxy.mjs` (handled in t2070), the next tier of opencode plugin complexity is a cluster of four related files: `cursor/proxy.js` (5 smells), `ttsr.mjs` (3 smells including a **125-complexity** function), `provider-auth.mjs` (3 smells), `google-proxy.mjs` (4 smells). They share architecture (provider proxy pattern) so decomposing them as a cluster keeps the idioms consistent.

## What

Decompose all four files so no function exceeds cyclomatic 15 and no file carries a qlty smell. Standardise the plugin shape (hook factory → handler dispatcher → per-event handlers) so future opencode plugins have a template to model on.

- `cursor/proxy.js` — 5 smells, `createThinkingTagFilter` (21) + `process` (19)
- `ttsr.mjs` — 3 smells, **`createTtsrHooks` (125)** ← single largest function in the repo
- `provider-auth.mjs` — 3 smells, `loadCCHConstants` (22) + internal dispatchers
- `google-proxy.mjs` — 4 smells, `startGoogleProxy` (29) + `fetch` (21)

After this change, `qlty smells --all --sarif | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("opencode-aidevops/(cursor|ttsr|provider-auth|google-proxy)"))] | length'` returns `0`.

## Why

- **`ttsr.mjs:createTtsrHooks` at cyclomatic 125** is the single largest function in the repo. It likely bundles hook registration, event routing, TTS provider selection, and queue management into one mega-function. Splitting it alone is worth the task.
- 15 total smells across 4 files = ~14% progress toward A in one cluster task.
- Standardising the plugin shape provides a reference pattern for the higgsfield task (t2072) and any future opencode plugin.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Four files in a cluster, architectural consistency across them, one 125-complexity function that needs careful reading. Opus-tier.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Worker Quick-Start

```bash
# Per-file smell breakdown
for f in cursor/proxy.js ttsr.mjs provider-auth.mjs google-proxy.mjs; do
  echo "=== $f ==="
  ~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
    | jq -r --arg f ".agents/plugins/opencode-aidevops/$f" \
      '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri == $f) | "\(.ruleId)\t\(.message.text)\t\(.locations[0].physicalLocation.region.startLine)"'
done

# Reference pattern from t2070 (claude-proxy decomposition)
cat .agents/plugins/opencode-aidevops/claude-proxy-stream.mjs 2>/dev/null \
  || echo "t2070 not yet merged - design fresh pattern"
```

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/cursor/proxy.js`
- `EDIT: .agents/plugins/opencode-aidevops/ttsr.mjs`
- `EDIT: .agents/plugins/opencode-aidevops/provider-auth.mjs`
- `EDIT: .agents/plugins/opencode-aidevops/google-proxy.mjs`
- `NEW: sibling `_helpers.mjs`/`_handlers.mjs` files as needed per extraction`
- `EDIT: tests if any`

### Implementation Steps

1. **Read each file end to end, catalogue the high-complexity functions, sketch the extraction plan.** This is a decomposition cluster — read all 4 files before writing any refactor code. Budget 1.5h for reading.

2. **`ttsr.mjs:createTtsrHooks` (125)** — the biggest single target. Break it into:
   - A registration function (receives opencode's hook API, returns the handler map)
   - A per-event handler for each opencode hook the TTS system attaches to
   - Provider selection + queue management as separate helpers
   - Target: top-level ≤ 20, each handler ≤ 12

3. **`google-proxy.mjs:startGoogleProxy` (29), `fetch` (21)** — apply the same pattern used in claude-proxy (t2070): event-type dispatcher + per-event handlers.

4. **`cursor/proxy.js:createThinkingTagFilter` (21), `process` (19)** — `createThinkingTagFilter` is a transform stream with state; extract state machine transitions into a table-driven form.

5. **`provider-auth.mjs:loadCCHConstants` (22)** — likely a config-loading function with per-provider branches. Pull each provider's config loader into its own function.

6. **Establish a plugin-shape convention** in a short comment at the top of one of the files (or a new `_plugin-pattern.md` doc) so t2072 and future plugins can model on it.

### Verification

```bash
# Zero smells across all 4 files
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("opencode-aidevops/(cursor|ttsr|provider-auth|google-proxy)"))] | length'
# Expected: 0

# Plugin still loads
cd .agents/plugins/opencode-aidevops && node -e "import('./ttsr.mjs').then(() => console.log('ok'))"
cd .agents/plugins/opencode-aidevops && node -e "import('./google-proxy.mjs').then(() => console.log('ok'))"
```

## Acceptance Criteria

- [ ] Zero qlty smells on all four files and any extracted sibling files
- [ ] No function exceeds cyclomatic 15 in any of the modified files
- [ ] `createTtsrHooks` specifically drops from 125 to ≤ 20 (top-level dispatcher only)
- [ ] Opencode plugin tests pass (`bun test` in `.agents/plugins/opencode-aidevops/`)
- [ ] Plugin shape convention documented (short comment in one file OR `_plugin-pattern.md`)
- [ ] Repo-wide total smell count drops by at least 12

## Context & Decisions

- **Why as one task?** Architectural consistency across related plugin files; splitting into 4 separate tasks produces 4 different styles. One worker with the whole cluster in context produces a coherent result.
- **Don't change plugin runtime semantics** — opencode attaches these hooks at well-defined lifecycle points. The refactor is structural only.

## Relevant Files

- `.agents/plugins/opencode-aidevops/claude-proxy.mjs` — reference pattern if t2070 lands first
- `.agents/plugins/opencode-aidevops/README.md` (if exists) — plugin architecture docs

## Dependencies

- **Blocked by:** none (but t2070 landing first gives a reference pattern)
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1.5h | Four files end-to-end |
| Characterisation tests | 1h | At least one test per high-complexity function |
| Implementation | 4h | Four-file refactor |
| Testing | 1h | Rerun + smoke |
| **Total** | **~7.5h** | |
