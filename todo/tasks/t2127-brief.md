---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2127: refactor(higgsfield) — clear residual file-complexity smells

## Origin

- **Created:** 2026-04-16
- **Session:** Claude:interactive
- **Created by:** ai-interactive (maintainer directed)
- **Parent task:** t2126 (#19222)
- **Conversation context:** Child of the qlty A-grade campaign. PR #18948 (GH#18780) cleared 9 function-level smells in the higgsfield cluster but intentionally deferred 4 file-complexity smells as follow-up. This task completes the deferral.

## What

Clear the 4 remaining `qlty:file-complexity` smells in `.agents/scripts/higgsfield/`:

| File | Lines | Complexity | Target |
|------|-------|-----------|--------|
| `higgsfield-commands.mjs` | 2024 | **334** | ≤ file_complexity default |
| `higgsfield-video.mjs` | 1415 | **297** | ≤ file_complexity default |
| `higgsfield-common.mjs` | 1506 | **283** | ≤ file_complexity default |
| `higgsfield-image.mjs` | ~600 | **102** | ≤ file_complexity default |

**Total current complexity across these 4 files: 1016.** Each file must be split into smaller modules with clear responsibility boundaries so `qlty smells --all` no longer reports file-complexity on any of them.

Deliverable:

1. Decomposed files, each under the `file_complexity` threshold (default ~60).
2. `verify-cluster.sh` (the existing characterisation test) continues to pass: parse, import resolution, `COMMON_EXPORTS_OK`, and qlty smell count on the cluster = 0.
3. All public CLI commands in the higgsfield entry-point work unchanged (no user-visible behavioural change).

## Why

**Hard blocker for ratchet-down.** These 4 files contribute 4 of the 20 remaining smells (20% of the budget). Until they clear, `QLTY_SMELL_THRESHOLD` cannot ratchet below 18, and we remain one new file away from losing grade A. The higgsfield module is also the most complex per-file (334 on commands.mjs is the single highest count in the repo), so leaving it alone guarantees the grade stays fragile.

This task is **completing a deferral**, not opening new work. The prior decomposition PR (#18948) explicitly documented these 4 files as "tracked for follow-up" in its Runtime Testing section.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? **NO — 4 files to split, plus N new sibling modules**
- [ ] Every target file under 500 lines? **NO — all 4 are 600-2024 lines**
- [ ] Exact `oldString`/`newString` for every edit? **NO — module boundary is a design decision**
- [x] No judgment or design decisions? **NO — worker must decide split points**
- [ ] No error handling or fallback logic to design? **NO**
- [ ] No cross-package or cross-module changes? Single cluster
- [ ] Estimate 1h or less? **NO — 3h**
- [ ] 4 or fewer acceptance criteria? **NO — 6**

**Selected tier:** `tier:thinking`

**Tier rationale:** Decomposition requires reading ~5000 lines across 4 files, identifying cohesive concern groups (browser automation, job polling, HTTP layer, formatters), and choosing split points that reduce complexity without just moving it sideways. Sonnet routinely produces shallow splits that trade one smell for another; Opus is the minimum for architectural slicing at this scale.

## PR Conventions

**Parent is `parent-task`** → PR body MUST use `For #19222` AND `Resolves #19223` (leaf child uses `Resolves` on its own issue; the parent closer is whichever cluster lands last). See `full-loop-helper.sh commit-and-pr` strict-mode enforcement.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Load the prior decomposition PR for context — this is the "Phase 1" that left Phase 2 pending:
gh pr view 18948 --json title,body

# 2. See the existing verify-cluster.sh characterisation harness (mandatory regression test):
cat .agents/scripts/higgsfield/verify-cluster.sh

# 3. Current smell counts (baseline before you start):
qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | startswith(".agents/scripts/higgsfield/")) | .locations[0].physicalLocation.artifactLocation.uri' | sort -u
# Expected: 4 files listed

# 4. Read all 4 files end-to-end BEFORE designing the split — don't grep-and-split:
wc -l .agents/scripts/higgsfield/higgsfield-{commands,video,common,image}.mjs
```

### Files to Modify

- `EDIT: .agents/scripts/higgsfield/higgsfield-commands.mjs` (2024 lines) — split per-command handlers into `higgsfield/commands/{auth,image,video,list,generate,download}.mjs` (exact boundary up to worker). The top-level file becomes a thin dispatcher.
- `EDIT: .agents/scripts/higgsfield/higgsfield-video.mjs` (1415 lines) — extract polling/download/matching pipeline into `higgsfield/video/{poll,download,matchers}.mjs`. Leave `higgsfield-video.mjs` as a public entry re-exporting the small surface the commands file calls.
- `EDIT: .agents/scripts/higgsfield/higgsfield-common.mjs` (1506 lines) — split into `higgsfield/common/{browser,state,selectors,formatters}.mjs`. Preserve the `required` exports list from verify-cluster.sh step 3: `parseArgs, withRetry, launchBrowser, dismissAllModals, BASE_URL, STATE_FILE, GENERATED_IMAGE_SELECTOR`.
- `EDIT: .agents/scripts/higgsfield/higgsfield-image.mjs` (~600 lines, complexity 102) — extract image-gen polling + selector logic into `higgsfield/image/{poll,selectors}.mjs`. This is the smallest split — probably 2 new files is enough.
- `NEW: .agents/scripts/higgsfield/commands/*.mjs`, `.agents/scripts/higgsfield/video/*.mjs`, `.agents/scripts/higgsfield/common/*.mjs`, `.agents/scripts/higgsfield/image/*.mjs` — sibling module directories.
- `EDIT: .agents/scripts/higgsfield/verify-cluster.sh` — only if new module glob patterns require updating the parse-check and export-check steps. Do NOT weaken the `COMMON_EXPORTS_OK` check — those exports are public contract.

### Implementation Steps

1. **Read all 4 target files end-to-end first.** No grep-and-split. Decomposition quality depends on seeing cohesive concern clusters, which only appear when you read the full surface.
2. **Map concern groups per file.** Write a throwaway concerns map (what functions touch what global state, who calls whom). This is the design step — it's exactly why this task is `tier:thinking`.
3. **Split one file at a time, in order: common → image → video → commands.** This is the dependency order (commands depends on video/image, video/image depend on common). Splitting in reverse creates broken intermediate states.
4. **After each file split, run `verify-cluster.sh`.** If it fails, fix before moving to the next file. Never accumulate multiple broken files.
5. **Preserve ALL public exports and ALL CLI commands.** The commands surface is a public contract — downstream scripts (`higgsfield/package.json` bin entries, any launchd plists) call by command name.
6. **Run `qlty smells --all` after all 4 splits.** The 4 file-complexity smells on these files must be gone. If any file is still flagged, split again — the worker's first cut was too shallow.
7. **Update `verify-cluster.sh` globs only if the new directory structure requires it.** Preserve the `COMMON_EXPORTS_OK` assertion exactly.

### Verification

```bash
# 1. Parse + import + export regression harness (the existing one, unchanged):
cd .agents/scripts/higgsfield && ./verify-cluster.sh
# Expected: all steps OK, final line "CLUSTER_OK"

# 2. No qlty file-complexity smells on the 4 target files:
qlty smells --all --sarif 2>/dev/null | \
  jq -r '.runs[0].results[] | select(.ruleId == "qlty:file-complexity") | .locations[0].physicalLocation.artifactLocation.uri' | \
  grep -E 'higgsfield/(higgsfield-commands|higgsfield-video|higgsfield-common|higgsfield-image)\.mjs$' | \
  wc -l
# Expected: 0

# 3. CLI commands still work (smoke test — no browser launch needed):
node .agents/scripts/higgsfield/higgsfield-commands.mjs --help 2>&1 | grep -c "Usage:"
# Expected: ≥ 1
```

## Acceptance Criteria

- [ ] `verify-cluster.sh` passes end-to-end with no modifications weakening the export assertion
  ```yaml
  verify:
    method: bash
    run: "cd .agents/scripts/higgsfield && ./verify-cluster.sh >/tmp/vc.log 2>&1 && grep -q CLUSTER_OK /tmp/vc.log"
  ```
- [ ] Zero `qlty:file-complexity` smells on the 4 target files
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.ruleId == \"qlty:file-complexity\") | .locations[0].physicalLocation.artifactLocation.uri' | grep -cE 'higgsfield/(higgsfield-commands|higgsfield-video|higgsfield-common|higgsfield-image)\\.mjs$') -eq 0"
  ```
- [ ] Total repo smell count decreased by at least 4 vs merge-base
  ```yaml
  verify:
    method: manual
    prompt: "Check PR regression gate comment — net reduction ≥ 4"
  ```
- [ ] All `required` exports from `higgsfield-common.mjs` still resolvable after the split (the verify-cluster step 3 check)
- [ ] No new `qlty:function-complexity`, `qlty:nested-control-flow`, or `qlty:boolean-logic` smells introduced on the new sibling modules (split must not trade file-complexity for function-complexity)
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq -r '.runs[0].results[] | select(.ruleId | IN(\"qlty:function-complexity\",\"qlty:nested-control-flow\",\"qlty:boolean-logic\")) | .locations[0].physicalLocation.artifactLocation.uri' | grep -cE 'higgsfield/') -eq 0"
  ```
- [ ] `node --check` passes for every .mjs file in `.agents/scripts/higgsfield/` and its new subdirectories
  ```yaml
  verify:
    method: bash
    run: "find .agents/scripts/higgsfield -name '*.mjs' -exec node --check {} \\;"
  ```

## Context & Decisions

- **Why 4 files not 1:** PR #18948 was the "cluster" pass. These 4 residuals are the heavy core that didn't fit the function-level split. They need module-level decomposition, which is why they were deferred.
- **Why split order matters:** common → image → video → commands is the topological dependency order. Splitting in reverse breaks imports and produces unrunnable intermediate states that fail `verify-cluster.sh`.
- **Non-goal:** refactoring higgsfield logic. This is a mechanical extraction — no semantic changes. If you find a bug, file a separate issue, do not fix it here.
- **Non-goal:** touching `higgsfield-api.mjs`, `higgsfield-api-client.mjs`, `playwright-automator.mjs`, or `remotion/`. Those are not in the 20-smell list.
- **Prior art:** PR #18893 (claude-proxy decomposition, 6 sibling modules) is the cleanest exemplar of this pattern in the repo. PR #18948 (the Phase 1 higgsfield pass) shows how to preserve characterisation tests through a split.
- **Characterisation test first:** the `verify-cluster.sh` harness is non-negotiable. It's the contract test that catches "I moved the code but broke an import". Run it after every individual file split, not just at the end.

## Relevant Files

- `.agents/scripts/higgsfield/higgsfield-commands.mjs:1` — 2024 lines, complexity 334 (the biggest offender)
- `.agents/scripts/higgsfield/higgsfield-video.mjs:1` — 1415 lines, complexity 297
- `.agents/scripts/higgsfield/higgsfield-common.mjs:1` — 1506 lines, complexity 283
- `.agents/scripts/higgsfield/higgsfield-image.mjs:1` — complexity 102
- `.agents/scripts/higgsfield/verify-cluster.sh` — the characterisation harness (MUST pass)
- `.agents/scripts/claude-proxy/` — reference pattern for sibling module layout (PR #18893)

## Dependencies

- **Blocked by:** none
- **Blocks:** parent t2126 (#19222) closure (needs all 5 children merged)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read all 4 files end-to-end | 45m | ~5000 lines total |
| Concerns map (design) | 30m | throwaway doc, but essential |
| Split common.mjs | 30m | foundation — others depend on it |
| Split image.mjs | 20m | smallest |
| Split video.mjs | 40m | — |
| Split commands.mjs | 40m | biggest — but also most mechanical (per-command) |
| verify-cluster.sh + qlty smells verification | 15m | iterate if first cut was shallow |
| **Total** | **~3.5h** | |
