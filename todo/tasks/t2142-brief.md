<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2142: Harden consolidation gate against unset threshold vars

## Origin

- **Created:** 2026-04-16
- **Session:** opencode:interactive
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** n/a
- **Conversation context:** Phase 1 of a three-phase response to #19255. Reporter observed a real consolidation cascade and attributed it to unset `ISSUE_CONSOLIDATION_COMMENT_*` vars. Review found the defensive gap is real (bash 5.x `[[ N -ge "" ]]` evaluates TRUE for any N) but the attributed production trigger path doesn't exist — `pulse-wrapper.sh:816-817` sets defaults at top-level under the only production sourcing path. This task hardens the defensive gap anyway; the cascade investigation is tracked separately in t2144.

## What

Add inline `${VAR:-default}` guards at three call sites in `_issue_needs_consolidation` so `pulse-triage.sh` remains correct when sourced standalone (tests, one-off scripts, future sourcing paths). Add a standalone test that sources the module with unset env and verifies the gate behaves correctly. Defaults must match `pulse-wrapper.sh:816-817` source of truth (threshold=2, min_chars=500).

## Why

Minimal defensive hardening that lets the architectural cleanup (t2143) land safely later. Zero regression risk — pure defensive additions with no change to initialization order.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** 2 files (pulse-triage.sh 891 lines + new test). File exceeds 500 lines, which disqualifies tier:simple. Narrative brief with exact oldString/newString blocks sufficient for standard tier.

## PR Conventions

Leaf issue — uses `Resolves #19343`.

## Status

**IMPLEMENTED.** PR #19344 open, mergeable. Awaiting review bot gate + merge.

## How

### Files Modified

- EDIT: `.agents/scripts/pulse-triage.sh` — lines 283 (add `${VAR:-500}`), 309 (add `${VAR:-2}`), 319 (log message consistency)
- NEW: `.agents/scripts/tests/test-consolidation-gate-defaults.sh` — 3 test cases

### Implementation Steps (completed)

1. Added inline `${VAR:-default}` at three call sites.
2. Wrote standalone test sourcing pulse-triage.sh with unset env.
3. Verified shellcheck clean and test passes 3/3.
4. Verified existing `test-consolidation-dispatch.sh` unchanged (1 pre-existing failure tracked separately).

### Verification

- `shellcheck .agents/scripts/pulse-triage.sh` clean
- `bash .agents/scripts/tests/test-consolidation-gate-defaults.sh` → 3/3 PASS with unset env
- `bash .agents/scripts/tests/test-consolidation-dispatch.sh` → same 1 pre-existing failure on main (not introduced by this PR)

## Acceptance criteria

- [x] Three inline `${VAR:-default}` guards applied
- [x] New test added and passes
- [x] Shellcheck clean
- [x] No new regressions
- [ ] PR merged
- [ ] `#19343` closed via `Resolves`

## Out of scope

- Phase 2 (t2143 / #19346): module-level default centralization.
- Phase 3 (t2144 / #19347): investigate the actual cascade in #19255.
- Pre-existing test failure in `test-consolidation-dispatch.sh` test_dispatch_creates_child_issue — noted in PR body, deferred to separate task.

Ref #19255
