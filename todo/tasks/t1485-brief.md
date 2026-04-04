---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1485: Split playwright-automator.mjs into focused modules (Qlty file-complexity 1272)

## Origin

- **Created:** 2026-03-15
- **Session:** claude-code:interactive (quality sweep session)
- **Created by:** AI DevOps (agent) + marcusquinn (human)
- **Conversation context:** Session improved daily quality sweep to be badge-score-aware, then systematically fixed 87 Qlty maintainability smells across 26 files (139 → 52). The remaining 19 file-complexity smells are irreducible without module splits. This file has the highest complexity (1272) in the codebase — a 6534-line monolith.

## What

Split `.agents/scripts/higgsfield/playwright-automator.mjs` (6534 lines, complexity 1272) into focused modules while preserving the single entry point CLI interface.

**Proposed module structure:**

1. **`higgsfield-api.mjs`** — API client, authentication, request handling
   - `apiRequest`, `apiExecuteFetch`, `parseApiErrorDetail`
   - `login`, `tryFillField`, `tryClickSubmit`, `isNonAuthUrl`
   - `estimateCreditCost`
   - ~800 lines, complexity ~120

2. **`higgsfield-discovery.mjs`** — Route discovery and page navigation
   - `runDiscovery`, `categoriseRoutes`, `diffRoutesAgainstCache`
   - `dismissInterruptions`, `dismissModalsAndBanners`, `dismissOverlaysAndAgreements`
   - ~400 lines, complexity ~80

3. **`higgsfield-image.mjs`** — Image generation and download
   - `configureImageOptions`, `setAspectRatio`, `setEnhanceToggle`
   - `waitForImageGeneration`, `checkImageGenCompletion`, `retryGenerateIfStalled`
   - `downloadImageViaDialog`, `downloadLatestResult`
   - `uploadStartFrame`
   - ~600 lines, complexity ~150

4. **`higgsfield-video.mjs`** — Video generation, polling, download
   - `waitForVideoGeneration`, `logVideoPollingProgress`
   - `fetchProjectApiWithPolling`, `fetchProjectApiData`, `evaluateNewestJobStatus`
   - `downloadVideoFromApiData`, `downloadMatchedVideos`, `matchJobSetsToSubmittedJobs`
   - `generateLipsync`, `extractDialogMetadata`
   - ~800 lines, complexity ~200

5. **`higgsfield-batch.mjs`** — Batch operations and pipeline orchestration
   - `batchVideo`, `submitVideoBatch`, `pollAndRecordVideoResults`
   - `runBatchJob`, `finalizeBatch`
   - `pipelineLipsync`, `assembleWithRemotion`
   - `cinemaStudio`, `assetChain`, `motionPreset`, `vibeMotion`
   - ~1000 lines, complexity ~250

6. **`playwright-automator.mjs`** — CLI entry point, orchestrator (imports from above)
   - `parseArgs`, `smokeTest`, `smokeTestNavigation`, `smokeTestCredits`
   - Main dispatch logic
   - ~500 lines, complexity ~80

## Why

At complexity 1272, this file is 25x the Qlty threshold (~50). It's the single largest contributor to the C maintainability grade. Splitting it into focused modules makes each module independently understandable, testable, and maintainable. The file has grown organically as features were added — the module boundaries are already implicit in the function groupings.

## How (Approach)

1. Read the full file and map all function definitions, their dependencies (what calls what), and shared state (module-level variables, constants)
2. Identify shared utilities (constants, helper functions used across modules) — these go in a `higgsfield-common.mjs` if needed
3. Create each module file with the appropriate functions, preserving JSDoc comments
4. Update `playwright-automator.mjs` to import from the new modules and re-export for backward compatibility
5. Verify with `node --check` on each file
6. Run `qlty smells` to confirm file-complexity drops below threshold for each module
7. Test the CLI entry point still works: `node playwright-automator.mjs --help`

**Key constraint:** The file uses Playwright `page` objects passed between functions. Module boundaries must respect this — functions that share a `page` instance should stay in the same module or accept it as a parameter.

## Acceptance Criteria

- [ ] Each new module has file-complexity below 300 (ideally below 100)
- [ ] `playwright-automator.mjs` file-complexity drops from 1272 to <100
- [ ] `node --check` passes on all new module files
- [ ] CLI entry point (`node playwright-automator.mjs --help`) still works
- [ ] No behavioral changes — pure structural refactoring
- [ ] All existing function signatures preserved (callers unaffected)

## Context

- **Model tier:** opus (large file, complex dependency analysis)
- **Estimated effort:** ~4h
- **Tags:** #refactor #quality #qlty #auto-dispatch
- **Branch pattern:** `refactor/split-playwright-automator`
