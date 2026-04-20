---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2433: fix(pulse): pull repo before large-file gate measures file size

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `large-file-gate false positive debt issue` → 0 hits — no relevant lessons (new finding from this session)
- [x] Discovery pass: 20+ commits on target files in last 48h (active simplification work), 0 merged PRs addressing pull-before-gate ordering, 0 open PRs on the same fix
- [x] File refs verified: 5 refs checked (pulse-wrapper.sh, pulse-dispatch-core.sh:867, pulse-dispatch-worker-launch.sh:530-540, pulse-triage.sh:624, tests/test-reeval-stale-continuation.sh), all present at HEAD
- [x] Tier: `tier:standard` — disqualifier check clean (4+ files, judgment required on refresh placement + cycle-scoped sentinel design)

## Canonical Brief

The canonical worker-ready brief is the GitHub issue body: **GH#20071** — https://github.com/marcusquinn/aidevops/issues/20071

The issue body contains all required sections (What, Why, How, Files to Modify, Implementation Steps, Verification, Acceptance Criteria, Session Origin, Context & Decisions). This file exists only to satisfy the brief-file-must-exist rule and to record the Pre-flight checkboxes.

## Origin

- **Created:** 2026-04-20
- **Session:** Claude Code interactive (maintainer)
- **Created by:** ai-interactive (marcusquinn)
- **Parent task:** none (leaf bug fix)
- **Conversation context:** User asked why simplification/file-size-debt issues kept triggering for `pulse-prefetch.sh` even after the split PR merged. Investigation traced 6 spurious file-size-debt issues (#19964, #19982, #19988, #20003, #20010, #20023) cited at >2000 lines when the actual file was 625 lines post-split. Root cause identified: the gate measures the local working copy without first pulling from remote; the only `git pull` in the dispatch path runs inside `_dlw_actually_dispatch_worker` AFTER the gate has already decided. Same systemic failure observed on `headless-runtime-lib.sh` and `shared-constants.sh`.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? — No, 4 existing files + 1 new test file
- [x] Every target file under 500 lines? — pulse-dispatch-worker-launch.sh:530-540 is a small removal; new test file is a skeleton
- [ ] Exact `oldString`/`newString` for every edit? — No, helper design requires the worker to synthesise the sentinel + function
- [ ] No judgment or design decisions? — No, must decide sentinel scope, placement relative to existing init
- [x] No error handling or fallback logic to design? — Existing `|| { echo ... }` pattern is inherited
- [x] No cross-package or cross-module changes? — All in `.agents/scripts/`
- [ ] Estimate 1h or less? — No, ~1.5-2h including test harness
- [x] 4 or fewer acceptance criteria? — No, 8 criteria

**Selected tier:** `tier:standard`

**Tier rationale:** 5 files across the pulse subsystem with a new helper design decision (sentinel scoping), a redundant-pull deletion that must not regress the original GH#17584 motivation, and a new test harness with simulated git remote state. Worker needs to read the integration points across pulse-wrapper/dispatch-core/triage and synthesise — not transcribe.

## PR Conventions

Leaf task: use `Resolves #20071` in the PR body.
