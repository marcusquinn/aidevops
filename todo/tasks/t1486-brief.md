---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1486: Split opencode-aidevops/index.mjs into focused modules (Qlty file-complexity 316)

## Origin

- **Created:** 2026-03-15
- **Session:** claude-code:interactive (quality sweep session)
- **Created by:** AI DevOps (agent) + marcusquinn (human)
- **Conversation context:** Systematic Qlty smell reduction session. This file had 12 smells reduced to 1 (file-complexity 316) via extract-function refactoring. The remaining smell requires module splitting.

## What

Split `.agents/plugins/opencode-aidevops/index.mjs` (2086 lines, complexity 316) into focused modules while preserving the OpenCode plugin interface.

**Proposed module structure:**

1. **`validators.mjs`** — Shell script quality validators
   - `validateReturnStatements`, `walkFunctionsForReturns`, `checkAndRecordMissingReturn`, `beginFunction`
   - `validatePositionalParams`, `checkPositionalParamLine`, `hasBarePositionalParam`, `hasUnescapedPositionalParam`
   - `ALLOWED_POSITIONAL_PATTERNS`, `PRICE_TABLE_PATTERNS`
   - ~250 lines, complexity ~60

2. **`quality-pipeline.mjs`** — Markdown and code quality checks
   - `runMarkdownQualityPipeline`, `checkMD031`, `checkTrailingWhitespace`
   - Quality-related constants and thresholds
   - ~150 lines, complexity ~40

3. **`ttsr.mjs`** — TTSR (Turn-Taking Style Rules) engine
   - `loadTtsrRules`, `mergeUserTtsrRules`
   - `messagesTransformHook`, `getRecentAssistantMessages`, `collectDedupedViolations`, `recordFiredViolations`, `buildCorrectionMessage`
   - ~300 lines, complexity ~70

4. **`agent-loader.mjs`** — Agent index loading and MCP tool application
   - `loadAgentIndex`, `parseToonSubagentBlock`, `collectLeafAgents`
   - `scanDirNames`, `tryRegisterMdAgent`
   - `applyAgentMcpTools`, `applyToolPatternsToAgent`
   - ~200 lines, complexity ~60

5. **`index.mjs`** — Plugin entry point, hook registration (imports from above)
   - Plugin lifecycle hooks (`activate`, `deactivate`)
   - Hook registration and event wiring
   - ~200 lines, complexity ~40

## Why

At complexity 316, this file is 6x the Qlty threshold. It contains 4 distinct subsystems (validation, quality, TTSR, agent loading) that have no dependencies on each other — they're only in the same file because they're all OpenCode plugin hooks. Splitting them makes each subsystem independently testable and easier to extend.

## How (Approach)

1. Map all exports and hook registrations in `index.mjs`
2. Identify which functions are called by the plugin hooks vs internal-only
3. Create each module with its functions and constants
4. Update `index.mjs` to import from modules and wire into plugin hooks
5. Verify with `node --check` on each file
6. Run `qlty smells` to confirm each module is below threshold

**Key constraint:** OpenCode plugins have a specific entry point contract. The `index.mjs` must remain the plugin entry point and export the expected hooks. Internal modules are implementation details.

## Acceptance Criteria

- [ ] Each new module has file-complexity below 100
- [ ] `index.mjs` file-complexity drops from 316 to <60
- [ ] `node --check` passes on all files
- [ ] OpenCode plugin still loads correctly
- [ ] No behavioral changes
- [ ] All hook signatures preserved

## Context

- **Model tier:** opus (complex plugin architecture, hook wiring)
- **Estimated effort:** ~2.5h
- **Tags:** #refactor #quality #qlty #auto-dispatch
- **Branch pattern:** `refactor/split-opencode-index`
