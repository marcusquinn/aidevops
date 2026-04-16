<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2143: Centralize consolidation gate defaults in pulse-triage.sh

## Origin

- **Created:** 2026-04-16
- **Session:** opencode:interactive
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** n/a
- **Conversation context:** Follow-up from review of #19255 (defensive hardening proposal). Phase 1 (#19343) landed minimal inline guards. Phase 2 removes the duplication and fixes a latent 200-vs-500 default mismatch between `pulse-wrapper.sh:816-817` and `pulse-triage.sh:499`.

## What

Move the consolidation gate defaults (`ISSUE_CONSOLIDATION_COMMENT_THRESHOLD=2`, `ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=500`) to a single module-level `: "${VAR:=default}"` block at the top of `pulse-triage.sh`. Simplify the Phase 1 inline `${VAR:-default}` guards back to bare `$VAR`. Align the `_consolidation_substantive_comments` function's fallback (line 499) from 200 to 500 so all call sites agree. Optionally remove the duplicate declarations from `pulse-wrapper.sh:816-817` once sourcing order is verified.

## Why

Phase 1 hardened the gate defensively but left default values duplicated across the module. A separate helper at `pulse-triage.sh:499` uses a different fallback (200 vs 500) — different functions in the same consolidation flow would produce different verdicts if `pulse-wrapper.sh`'s top-level block ever fails to run first. Single source of truth eliminates this bug class. This also resolves the "200-char filter" confusion noted in the #19255 review.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify? (pulse-triage.sh + optionally pulse-wrapper.sh = 2)
- [ ] Every target file under 500 lines? (pulse-triage.sh is 891 lines)
- [x] Exact oldString/newString for every edit? (provided in issue body)
- [ ] No judgment? (optional Edit 4 requires sourcing-order verification — judgment)
- [x] No error/fallback logic to design?
- [x] No cross-package changes?
- [x] Estimate under 1h?
- [x] 4 or fewer acceptance criteria? (7 total — too many for simple)

**Selected tier:** `tier:standard`

**Tier rationale:** pulse-triage.sh is 891 lines and Edit 4 involves sourcing-order verification. Not a simple transcription — needs model able to reason about module loading order.

## PR Conventions

Leaf issue — use `Resolves #19346`.

## Blocked by

#19343 (Phase 1) must merge first to avoid conflicting edits to pulse-triage.sh.

## How

See issue body at https://github.com/marcusquinn/aidevops/issues/19346 — contains full oldString/newString blocks for all edits and test additions.

### Files to Modify

- EDIT: `.agents/scripts/pulse-triage.sh` — lines 34 (insert module defaults), 287/313/323 (simplify Phase 1 guards), 499 (align 200→500)
- EDIT (optional): `.agents/scripts/pulse-wrapper.sh:816-817` — remove duplicate declarations
- EDIT: `.agents/scripts/tests/test-consolidation-gate-defaults.sh` — add 200→500 alignment assertion

### Implementation Steps

1. Add module-level `: "${VAR:=default}"` block after `_PULSE_TRIAGE_LOADED=1` in pulse-triage.sh.
2. Simplify the three Phase 1 inline guards at lines 287, 313, 323.
3. Align line 499 fallback to use bare `$VAR` (picks up module default=500).
4. Add test assertion for 200→500 alignment.
5. Verify sourcing order before Edit 4: `pulse-wrapper.sh` main() must call something that sources `pulse-triage.sh` BEFORE first consolidation function call.
6. Optionally remove pulse-wrapper.sh:816-817 if Step 5 confirms safe.

### Verification

- `shellcheck .agents/scripts/pulse-triage.sh .agents/scripts/pulse-wrapper.sh` clean
- `bash .agents/scripts/tests/test-consolidation-gate-defaults.sh` — 4/4 pass (3 existing + 1 new alignment)
- `bash .agents/scripts/tests/test-consolidation-dispatch.sh` — no new regressions beyond the pre-existing failure already tracked

## Acceptance criteria

- [ ] Phase 1 (#19343) merged before this starts
- [ ] Module-level defaults block added
- [ ] Inline Phase 1 guards simplified
- [ ] Line 499 fallback aligned 200→500
- [ ] New test assertion passes
- [ ] `shellcheck` clean
- [ ] Existing regression tests still pass
- [ ] OPTIONAL: pulse-wrapper.sh:816-817 removed if sourcing order verified

## Out of scope

- Phase 3 (t2144): investigate the actual cascade in #19255.
- Any new gate behaviour — this is pure refactor.

Ref #19255, #19343
