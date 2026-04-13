<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2010: stats-functions.sh phased decomposition (parent task)

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Plan landed:** 2026-04-13 (this PR — `todo/plans/stats-functions-decomposition.md`)
- **Parent context:** Plan §6 Phase 11 of t1962 (pulse-wrapper decomposition) explicitly noted: *"the large-file gate continues to fire for `stats-functions.sh` (3,164 lines)... scope as a separate decomposition plan."* This task is that separate plan + parent.
- **Why now:** the t1962 decomposition methodology is proven (10 phases, ~15 modules, 90% reduction, no regressions). Applying the same pattern to the next-largest violator is straightforward.

## What

**Parent task** for the phased decomposition of `.agents/scripts/stats-functions.sh` (3,164 lines, 48 functions). Mirrors the t1962 plan structure: characterization safety net → phased extractions → byte-preserving moves only → simplification deferred.

**This task is parent-only.** No code is moved by THIS issue, ever. The plan document was committed as part of the PR that opened this parent — see `todo/plans/stats-functions-decomposition.md`. Implementation lives in subtask issues filed sequentially as each prior phase merges.

**Tagged `#parent`** to invoke the t1986 dispatch guard — this issue must NEVER be dispatched directly to a worker. Only its child phase tasks dispatch. The dispatch loop observed on 2026-04-12T23:08-2026-04-13T00:19 UTC was caused by a jq null-handling bug in the guard (fixed independently by GH#18537), not by a misconfigured label on this issue.

## Why

- **3,164 lines** is the second-largest file in the codebase post-t1962, more than 1.5× the simplification gate's 2,000-line threshold.
- **48 functions** in one file means it routinely shows up in `--complexity-scan` runs and creates noise in PR review.
- **Methodology is proven** — t1962 ran for 10 phases without a single byte-level regression. The same pattern applied to a smaller file (~3,164 vs ~13,797) is a 3-phase project (Plan §6).
- **Currently sourced by `stats-wrapper.sh` and one test file only** (per the t1431 history) — minimal external surface means the orchestrator change is scoped.

## Tier

`tier:reasoning` — nominal only. **Never dispatched directly.** Each phase subtask gets its own tier (Phases 0-3 are all `tier:standard` per Plan §6 — mechanical extractions following an established methodology).

### Tier checklist

This is a parent tracking task. Tier assignment does not apply directly. Field is set for label-routing consistency only.

## How (parent role only)

The parent task tracks progress against `todo/plans/stats-functions-decomposition.md` and files each phase subtask sequentially. The parent itself does no code work.

### Phase tracker

- [ ] **Phase 0** — characterization safety net (test harness, `--self-check`, `--dry-run`). Plan §5, §6 Phase 0. `tier:standard`. Subtask filed as part of this PR (see `## Filed children` below).
- [ ] **Phase 1** — extract `stats-shared.sh` (3 fns, ~120 lines). Plan §6 Phase 1. File after Phase 0 merges.
- [ ] **Phase 2** — extract `stats-quality-sweep.sh` (23 fns, ~1,692 lines). Plan §6 Phase 2. File after Phase 1 merges.
- [ ] **Phase 3** — extract `stats-health-dashboard.sh` (22 fns, ~1,252 lines). Plan §6 Phase 3. File after Phase 2 merges.
- [ ] **Phase 4 (optional)** — clear the simplification gate, lower `FILE_SIZE_THRESHOLD` ratchet. Plan §6 Phase 4.

**File Phase N+1 only after Phase N merges.** This is the t1962 sequencing rule — prevents workers from picking up phases whose prerequisites have not landed.

## Acceptance Criteria

Parent-task acceptance is binary on plan + child completion:

- [x] Plan doc `todo/plans/stats-functions-decomposition.md` committed with all 11 sections
- [x] `#parent` tag applied so the dispatch guard (t1986) prevents this issue from being dispatched to workers
- [x] Phase 0 child subtask filed with brief and TODO entry (this PR)
- [ ] Phase 0 merged (all of §5.1, §5.2, §5.3 deliverables)
- [ ] Phase 1 merged (`stats-shared.sh` extracted)
- [ ] Phase 2 merged (`stats-quality-sweep.sh` extracted)
- [ ] Phase 3 merged (`stats-health-dashboard.sh` extracted, orchestrator residual ≤80 lines)
- [ ] Verification: `bash .agents/scripts/stats-wrapper.sh --self-check` passes against the fully decomposed state

## Relevant Files

- `todo/plans/stats-functions-decomposition.md` — **the authoritative plan** (committed in this PR)
- `.agents/scripts/stats-functions.sh` — the target (3,164 lines, 48 functions)
- `.agents/scripts/stats-wrapper.sh` — the canonical sourcer (per t1431 history)
- `.agents/scripts/tests/test-quality-sweep-serialization.sh` — second real sourcer (test fixture, exercises Cluster C)
- `todo/plans/pulse-wrapper-decomposition.md` — methodology template
- `todo/tasks/t1962-brief.md` — parent-task brief template

## Dependencies

- **Blocked by:** none
- **Blocks:** any future simplification that touches stats-functions.sh; the file-size threshold ratchet-down (`FILE_SIZE_THRESHOLD` is currently 59 partly because of this file)
- **Related:** t1962 (the precedent), t1986 (parent-task dispatch guard), GH#18537 (jq null-fallback fix that closed the dispatch-loop hole)
- **Methodology source:** every PR merged in t1962 (Phases 0-10) — the pattern is locked in

## Estimate

**Parent task overhead:** ~0h. The parent is administrative; it tracks children and files the next phase when the prior one merges.

**Plan-writing overhead (this PR):** ~3h (interactive). Function inventory, call-graph analysis, cluster derivation, plan doc.

**Full stats-functions decomposition (Phases 0-3):** ~10-12h spread across 4 phases:

- Phase 0 — safety net: 2-3h, `tier:standard`
- Phase 1 — `stats-shared.sh`: 1-2h, `tier:standard`
- Phase 2 — `stats-quality-sweep.sh`: 3-4h, `tier:standard`
- Phase 3 — `stats-health-dashboard.sh`: 3-4h, `tier:standard`

Smaller than t1962's ~35h because the file is 23% the size and has cleaner cluster boundaries (zero edges between health and quality clusters, one edge from health to shared utilities).

## Out of scope (for THIS task — but in scope for the children it spawns)

- Any actual extraction (Phases 1-3 own that)
- Any function simplification (deferred to follow-up tasks once modules exist in isolation)
- Any rename or API change
- Splitting `stats-wrapper.sh` itself (it's small at 189 lines)
