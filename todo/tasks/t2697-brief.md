---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2697: Harden plugin re-export regression test to auto-discover all plugin .mjs files

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `plugin reexport test auto-discover` → 0 hits — no prior lessons (expected; this test shipped in v3.8.91)
- [x] Discovery pass: 1 commit (7f504cefa, merge of PR #20320 that introduced the test) / 1 merged PR (#20320) / 0 open PRs touch target file in last 48h
- [x] File refs verified: 1 ref checked, present at HEAD (`.agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs:128-133`)
- [x] Tier: `tier:simple` — single-file test change, exact diff block provided, no design decisions

## Origin

- **Created:** 2026-04-21
- **Session:** opencode:interactive (post-v3.8.91 hardening)
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** After shipping v3.8.91 with a regression test for the re-export-only-used-locally pattern (PR #20320), we noted the test only covers 4 hardcoded files out of 47 plugin .mjs files. New plugin files with the same bug pattern would slip through silently. Store-a-lesson-in-memory protects only the session that recalls it; framework-wide protection requires shipping the fix in code.

## What

Replace the hardcoded `CANDIDATES` list in `.agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs` with an auto-discovery loop that reads the plugin directory and runs the regression check against every `.mjs` file except `index.mjs`. After the change, all 46 non-entry-point plugin files are covered; any new plugin `.mjs` file added to the directory is automatically tested — no manual CANDIDATES maintenance required.

## Why

The hardcoded list (4 files) covers ~8.5% of the 47 plugin `.mjs` files. The re-export-only-used-locally bug is a silent runtime failure (`ReferenceError: X is not defined` at call time), and the test exists specifically to catch it at CI time. When a new plugin file lands with the same pattern, the hardcoded list does not protect against it — defeating the whole point of having the test. Auto-discovery closes this gap structurally.

This is the code counterpart to the meta-lesson: protections must ship in code (tests, lint rules, workflow checks) to reach all users of the framework — memory recall only benefits the session that queries for it.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** 1 file
- [x] **Every target file under 500 lines?** 144 lines
- [x] **Exact `oldString`/`newString` for every edit?** Yes — two small blocks below
- [x] **No judgment or design decisions?** Mechanical replacement; exclusion of `index.mjs` is the only filter
- [x] **No error handling or fallback logic to design?** None — `readdirSync` throws on missing dir, which is already a test-infrastructure error
- [x] **No cross-package or cross-module changes?** Single file
- [x] **Estimate 1h or less?** ~15 min including verification
- [x] **4 or fewer acceptance criteria?** 3 criteria

All checked = `tier:simple`.

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file test change with two verbatim oldString/newString blocks provided. No judgment required — auto-discovery pattern is `readdirSync(dir).filter(...).sort()`. Exclusion of `index.mjs` is a single equality check. Passes all simple-tier disqualifiers.

## PR Conventions

Leaf (non-parent) issue — PR body uses `Resolves #NNN` as normal.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs:22` — add `readdirSync` to the `node:fs` import
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs:127-133` — replace hardcoded `CANDIDATES` array with auto-discovery call

### Implementation Steps

1. Add `readdirSync` to the existing `node:fs` import at line 22.

**oldString:**

```javascript
import { readFileSync } from "node:fs";
```

**newString:**

```javascript
import { readFileSync, readdirSync } from "node:fs";
```

2. Replace the hardcoded `CANDIDATES` array with an auto-discovery loop that enumerates all `.mjs` files in `pluginDir` except `index.mjs` (the plugin entry point, which re-exports everything and is the one file where re-export-only semantics are intended).

**oldString:**

```javascript
// Files known to use the re-export pattern — extend when new ones land.
const CANDIDATES = [
  "quality-hooks.mjs",
  "google-proxy.mjs",
  "oauth-pool.mjs",
  "agent-loader.mjs",
];
```

**newString:**

```javascript
// Auto-discover all plugin .mjs files except the entry point (index.mjs).
// Rationale: hardcoded lists silently miss new files that ship with the
// re-export-only-used-locally bug pattern. t2697 closes that gap by scanning
// the plugin directory on every test run. `index.mjs` is excluded because it
// is a pure re-export barrel — the pattern this test flags is legitimate there.
const CANDIDATES = readdirSync(pluginDir)
  .filter((name) => name.endsWith(".mjs") && name !== "index.mjs")
  .sort();
```

3. Run the test locally to confirm all 46 files pass (no regressions from v3.8.91's fix).

### Verification

```bash
# All 46 non-entry-point plugin .mjs files should be tested and pass.
cd /Users/marcusquinn/Git/aidevops
node --test .agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs 2>&1 | tail -20

# Expected: "tests 46" (not 4). Zero failures.
# Confirm test count bumped from 4 to 46:
node --test .agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs 2>&1 | grep -E "^# tests"
```

### Files Scope

- `.agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs`
- `TODO.md`
- `todo/tasks/t2697-brief.md`

## Acceptance Criteria

- [ ] Test count bumps from 4 to 46 (one per non-index `.mjs` plugin file).

  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && node --test .agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs 2>&1 | grep -qE '^# tests 46$'"
  ```

- [ ] All 46 tests pass (no regressions from the existing v3.8.91 fix).

  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && node --test .agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs 2>&1 | grep -qE '^# fail 0$'"
  ```

- [ ] No hardcoded file names remain in the CANDIDATES definition.

  ```yaml
  verify:
    method: codebase
    pattern: '"quality-hooks\.mjs"'
    path: ".agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs"
    expect: absent
  ```

## Context & Decisions

- **Why `index.mjs` is excluded:** `index.mjs` is the plugin entry point — it legitimately uses `export { X } from "./Y"` to re-export everything without needing local bindings. The test would false-positive on it.
- **Why sort():** Deterministic test ordering aids debugging when a specific file fails.
- **Why not glob:** `readdirSync` + `filter` is a single stdlib call, no dependency. Matches the test's existing "vanilla node" style.
- **Rejected alternative:** Adding a comment above the hardcoded list saying "remember to update this". That IS the current state; it has already failed once (only 4 of 47 files covered after v3.8.91 merged).
- **Not goals:** Refactoring the test's detection logic. Changing how `findReExportLocalUseViolations` works. Adding new detection rules. This task is scoped to the CANDIDATES enumeration only.

## Relevant Files

- `.agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs:22` — import statement to extend
- `.agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs:127-133` — hardcoded array to replace
- `.agents/plugins/opencode-aidevops/index.mjs` — the one file correctly excluded from scanning
- `.github/workflows/plugin-import-check.yml` — runs this test; no changes needed (already invokes the test file)

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing critical, but defensive for any future plugin file additions
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 2m | Read the 144-line test file |
| Implementation | 5m | Two small edits |
| Testing | 5m | Run `node --test` locally, confirm count is 46 and all pass |
| **Total** | **~15m** | |
