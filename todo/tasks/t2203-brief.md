<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2203 Brief — Extract _route_pr_to_fix_worker helper to deduplicate pulse-merge.sh routing gates

**Issue:** GH#19687 (marcusquinn/aidevops) — issue body is the canonical spec.

## Session origin

Filed 2026-04-18 from the t2189 interactive session (PR #19682). t2189 added `origin:worker-takeover` as a second routing signal and updated three routing gates in `pulse-merge.sh` — the review gate, conflict gate, and CI gate all now do structurally the same thing. The PR bumped `pulse-merge.sh` nesting depth from 36 → 42. Ratchet gate passes (file was already over the 8-depth threshold), but the debt is accumulating and the next routing-signal addition would triple-hit again.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19687 for:
- The three gate locations in `pulse-merge.sh` (review ~:836, conflict ~:1115, CI ~:1162)
- Shared structure across all three (label fetch → exclusion check → origin-based dispatch)
- Target helper signature `_route_pr_to_fix_worker(pr, slug, issue, kind)` with `kind ∈ {review, conflict, ci}`
- Case-statement dispatch over kind (no dynamic function calls)
- Per-kind return semantics to preserve (review: fall-through, conflict: return 2, CI: return 1 fall-through)

## Acceptance criteria

Listed in issue body. Key gates: all 21 tests across three test harnesses still pass; nesting-depth drops (target ≤ 36); helper <100 lines (function-complexity gate); no new violations reported.

## Tier

`tier:standard` — an internal refactor with good test coverage already in place. The 21 existing tests provide a safety net. No novel design.

## Blocked by

- **t2189** (PR #19682) — must merge first so the three gates exist in their final form before refactor. TODO entry has `blocked-by:t2189`.

## Why this matters

This isn't just aesthetic. The duplication is the reason the nesting depth jumped in PR #19682. Leaving this unrefactored means:
1. The next routing signal triples the change footprint
2. The three sites WILL drift — one site gets a new guard added, other two don't (already happened with `no-takeover` in PR #19682 — I had to manually paste it three times)
3. The pulse-merge.sh complexity trend curves upward with every feature
