<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2006: Phase 12 — split `calculate_priority_allocations()` (114 lines)

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** t1962 Phase 12 follow-up (plan §6, candidate #8 — the smallest)
- **Function location:** `.agents/scripts/pulse-capacity-alloc.sh:388` (extracted in Phase 3, t1971 / #18376)

## What

Split `calculate_priority_allocations()` (114 lines) into per-priority-class allocation helpers. The function decides how many worker slots go to `tooling`, `product`, `profile`, `quality-debt`, and `foss` priorities given current capacity.

Target structure:
1. **`_alloc_tooling_floor()`** — minimum floor for tooling
2. **`_alloc_product_floor()`** — minimum floor for product
3. **`_alloc_remaining_split()`** — how to distribute leftover capacity
4. Parent becomes coordinator. <40 lines.

OR a simpler split: extract just the rule-evaluation logic (the `if/elif` decision tree) into a single `_compute_priority_allocation_for_class()` helper that takes (class, capacity, ratio) and returns the slot count.

## Why

- 114 lines is the smallest of the Phase 12 candidates, but it's the function whose extraction in Phase 3 caused the very first complexity threshold bump (40→43, see PR #18377). Reducing it would let us start ratcheting the threshold back down.
- The allocation logic is hard to reason about because all priority classes share one giant if/elif tree. Per-class helpers make the rules per-class explicit.

## Tier

`tier:simple`. Smallest function in the Phase 12 backlog. Mechanical split with clear seams. Brief has explicit file:line, verbatim split target, clear acceptance criteria.

### Tier checklist

- [x] **2 or fewer files to modify?** — 1 file (`pulse-capacity-alloc.sh`)
- [x] **Complete code blocks for every edit?** — yes (the function is small enough to read in one shot)
- [x] **No judgment or design decisions?** — minor: which split shape (3 helpers vs 1 helper). Brief recommends both options.
- [x] **No error handling or fallback logic to design?** — none
- [x] **Estimate 1h or less?** — yes
- [x] **4 or fewer acceptance criteria?** — 4 below

6/6 pass → `tier:simple` (Haiku) is appropriate. **But note:** the function is part of the dispatch capacity logic. A regression here would silently mis-allocate workers. Test coverage is the live pulse cycles + characterization test. Worker should run a sandbox dry-run and visually compare allocation log lines before/after.

**Selected tier:** `tier:simple`

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-capacity-alloc.sh:388-501` — `calculate_priority_allocations()` body
- **VERIFY:** live pulse log line `Priority allocations: product_min=N tooling_max=M` — must show same numbers for same input

### Recommended split (option A — per-class helpers)

```bash
calculate_priority_allocations() {
    local total_capacity="$1"
    local tooling=$(_alloc_tooling_floor "$total_capacity")
    local product=$(_alloc_product_floor "$total_capacity")
    local remaining=$((total_capacity - tooling - product))
    _alloc_remaining_split "$tooling" "$product" "$remaining"
}
```

### Recommended split (option B — single rule helper)

```bash
calculate_priority_allocations() {
    local total_capacity="$1"
    local product_min tooling_max foss_max ...
    product_min=$(_compute_priority_alloc product "$total_capacity")
    tooling_max=$(_compute_priority_alloc tooling "$total_capacity")
    ...
    printf 'product_min=%d tooling_max=%d ...\n' "$product_min" "$tooling_max" ...
}
```

Worker should pick whichever produces cleaner code after reading the original.

### Verification

```bash
bash -n .agents/scripts/pulse-capacity-alloc.sh
.agents/scripts/pulse-wrapper.sh --self-check
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/pulse-capacity-alloc.sh

# Capture allocation output before and after — must be byte-identical for same input
_BEFORE=$(git stash)  # save current state
.agents/scripts/pulse-wrapper.sh --self-check 2>&1 | grep "Priority allocations" > /tmp/alloc-after
git stash pop
.agents/scripts/pulse-wrapper.sh --self-check 2>&1 | grep "Priority allocations" > /tmp/alloc-before
diff /tmp/alloc-before /tmp/alloc-after  # must be empty
```

## Acceptance Criteria

- [ ] `calculate_priority_allocations()` reduced to under 30 lines
- [ ] At least 1 new helper extracted (preferred: per-class helpers, but a single computation helper is acceptable)
- [ ] **Allocation output byte-identical for same input** (verified via the diff above)
- [ ] `shellcheck` no new findings

## Relevant Files

- `.agents/scripts/pulse-capacity-alloc.sh:388`
- PR #18377 — the first threshold bump triggered by this function's extraction (proves the function is on the bubble)

## Dependencies

- **Related:** t1999-t2005 (sibling per-function splits)
- **Enables:** ratcheting `FUNCTION_COMPLEXITY_THRESHOLD` back down by 1

## Estimate

~45m. Smallest brief in the batch.
