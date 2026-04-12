<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2010: stats-functions.sh phased decomposition (parent task)

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent context:** Plan §6 Phase 11 of t1962 (pulse-wrapper decomposition) explicitly noted: *"the large-file gate continues to fire for `stats-functions.sh` (3,125 lines)... scope as a separate decomposition plan."* This task is that separate plan + parent.
- **Why now:** the t1962 decomposition methodology is proven (10 phases, 23 modules, 90% reduction, no regressions). Applying the same pattern to the next-largest violator is straightforward and the cost amortizes (the methodology stays the same; only the function/cluster map differs).

## What

**Parent task** for the phased decomposition of `.agents/scripts/stats-functions.sh` (3,125 lines, 48 functions). Mirrors the t1962 plan structure: characterization safety net → phased extractions → byte-preserving moves only → simplification deferred.

This task is **plan-only**. No code is moved by THIS issue. Implementation lives in subtask issues filed once the plan is reviewed and approved.

**Tagged `#parent`** to invoke the t1986 dispatch guard — this issue must NEVER be dispatched directly to a worker. Only its (eventual) child phase tasks dispatch.

## Why

- **3,125 lines** is the second-largest file in the codebase post-t1962, more than 2× the simplification gate threshold.
- **48 functions** in one file means the file routinely shows up in `--complexity-scan` runs and creates noise in PR review.
- **Methodology is proven** — t1962 ran for 10 phases without a single byte-level regression. The same pattern applied to a smaller file (~3,125 vs ~13,797) should be a 4-6 phase project at most.
- **Currently sourced by `stats-wrapper.sh`** (per the t1431 history) — a single, well-defined sourcer means the orchestrator changes are scoped to one file. Easier than the pulse-wrapper case which had many call sites.

## Tier

`tier:reasoning`. This is plan + decomposition design work. The brief alone is the deliverable; the plan doc is the substance. Worker must:
- Read all 48 functions and group them by call graph + concern
- Decide cluster boundaries minimizing cross-cluster edges
- Sequence the phases to start with leaves and end with the orchestrator residual
- Estimate each phase's scope and risk
- Write the plan doc (modeled on `todo/plans/pulse-wrapper-decomposition.md`)

This is the same kind of work that produced the t1962 plan. That plan was ~830 lines. This one will be ~400-500 lines because the file is smaller.

### Tier checklist

All 6 fail. `tier:reasoning`.

## How

### Pre-work — read the precedent

```bash
# 1. The t1962 plan — model for this one
cat todo/plans/pulse-wrapper-decomposition.md

# 2. The Phase 0 safety net pattern (characterization tests)
cat .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# 3. The two-commit PR structure used in every t1962 phase
gh pr view 18366 --repo marcusquinn/aidevops  # Phase 1
gh pr view 18392 --repo marcusquinn/aidevops  # Phase 10 (final)
```

### Step 1 — characterise stats-functions.sh

```bash
# Function inventory
grep -n "^[a-zA-Z_][a-zA-Z0-9_]*() {" .agents/scripts/stats-functions.sh | wc -l  # confirm 48
grep -n "^[a-zA-Z_][a-zA-Z0-9_]*() {" .agents/scripts/stats-functions.sh > /tmp/stats-fn-inventory.txt

# Per-function line counts (largest first)
awk '
/^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ { fname=$1; sub(/\(\)/,"",fname); start=NR; next }
fname && /^\}$/ { lines=NR-start; print lines, fname; fname="" }
' .agents/scripts/stats-functions.sh | sort -rn > /tmp/stats-fn-sizes.txt

# Inter-function call graph (which functions call which others within the same file)
for fn in $(awk '{print $1}' /tmp/stats-fn-inventory.txt | sed 's/() {//'); do
    callers=$(grep -c "\\b${fn}\\b" .agents/scripts/stats-functions.sh)
    echo "$callers $fn"
done | sort -rn > /tmp/stats-fn-call-counts.txt

# External callers (who calls into stats-functions.sh from outside)
rg -l "stats-functions" .agents/scripts/ --type sh
```

### Step 2 — derive cluster map

Group functions by:
1. **Concern** — what does this function compute? Stats over what input?
2. **Call graph locality** — which functions call which others? Cluster tightly-coupled functions together.
3. **Size** — target sub-modules of 200-700 lines each (small enough to review, large enough to be coherent).

Sketch (worker should validate by reading actual code):

- **`stats-fetchers.sh`** — functions that pull raw data from `gh`, `git`, or files (~10-15 fns)
- **`stats-aggregators.sh`** — functions that bucket / sum / average raw data into shaped results (~10-15 fns)
- **`stats-formatters.sh`** — functions that turn shaped results into markdown / TSV / JSON output (~10-15 fns)
- **`stats-wrapper.sh` orchestrator residual** — the top-level entry points + globals + bootstrap (~5-10 fns)

Or if the call graph suggests different boundaries (e.g. by domain: per-issue stats vs per-PR stats vs per-repo stats), use those instead. Pick whichever produces fewer cross-cluster edges.

### Step 3 — write the plan doc

Create `todo/plans/stats-functions-decomposition.md`. Use `todo/plans/pulse-wrapper-decomposition.md` as the template. Required sections:

1. **Problem statement** — file size, complexity, current state
2. **Constraints** — byte-preserving moves only, sourcers must continue to work, etc.
3. **Cluster map** — full 48-function → cluster mapping. The substantive part.
4. **Inter-cluster edges** — call graph between proposed clusters
5. **Global state audit** — what globals does the file expose? Who reads them?
6. **Regression safety net** — characterization test, --self-check pattern, dry-run
7. **Phase sequence** — Phase 0 (safety net) + 4-6 extraction phases + final orchestrator
8. **Extraction methodology** — module template, two-commit PR structure, verification gauntlet (copy from t1962 plan §7)
9. **Rules** — same as t1962 §10 (no refactoring during extraction, etc.)

### Step 4 — file the Phase 0 subtask

Once the plan is on main, file ONE follow-up task: `tNNNN: stats-functions decomposition Phase 0 — safety net`. That phase task is the entry point for actual implementation work and can be auto-dispatched normally.

DO NOT file all phase subtasks upfront. The t1962 pattern was: file Phase 0 + parent, and let each subsequent phase be filed sequentially after the prior one merges. This avoids dispatching workers to phases that depend on prior phases not yet landed.

## Acceptance Criteria

- [ ] Function inventory generated and documented in PR body (size distribution, top-10 largest)
- [ ] Cluster map derived from call-graph analysis (not just from function name heuristics)
- [ ] Plan doc `todo/plans/stats-functions-decomposition.md` created with all 9 sections, modeled on the t1962 plan
- [ ] Phase 0 subtask filed with brief (`todo/tasks/tNNNN-brief.md`) and TODO entry
- [ ] **No code in `.agents/scripts/stats-functions.sh` is moved by this PR** — this is plan-only
- [ ] `#parent` tag applied so the dispatch guard (t1986) prevents this issue from being dispatched to workers

## Relevant Files

- `.agents/scripts/stats-functions.sh` — the target (3,125 lines, 48 functions)
- `.agents/scripts/stats-wrapper.sh` — the canonical sourcer (per t1431 history)
- `todo/plans/pulse-wrapper-decomposition.md` — methodology template
- `todo/tasks/t1962-brief.md` — parent-task brief template

## Dependencies

- **Blocked by:** none
- **Blocks:** any future simplification that touches stats-functions.sh; the file-size threshold ratchet-down (`FILE_SIZE_THRESHOLD` is currently 59 partly because of this file)
- **Related:** t1962 (the precedent), t1987 (sibling Phase 12 module split inside the pulse wrapper)
- **Methodology source:** every PR merged in t1962 (Phases 0-10) — the pattern is locked in

## Estimate

**For THIS task (plan + parent only):** ~4h. Breakdown: 1h read stats-functions.sh end-to-end + 1h call graph analysis + 1.5h plan doc writing + 30m Phase 0 brief.

**For the FULL stats-functions decomposition (parent + children):** ~15-20h spread across 4-6 phases, modeled after t1962's 35h spread across 10 phases (smaller because the file is ~25% the size).

## Out of scope (for THIS task — but in scope for the children it spawns)

- Any actual extraction
- Any function simplification
- Any rename or API change
- Splitting `stats-wrapper.sh` itself (it's small)
