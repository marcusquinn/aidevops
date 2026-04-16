<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2146: memory-pressure-monitor Bash 3.2 compat + re-exec guard

## Origin

- **Created:** 2026-04-16
- **Session:** opencode:interactive (claude-opus-4-6)
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** n/a
- **Conversation context:** Investigating a `Code Quality Analysis` failure on PR #19344 (`t2142: harden consolidation gate against unset threshold vars`). The failing job was `Bash 3.2 Compatibility`: 78 violations vs threshold 76. Root cause analysis showed PR #19344 itself introduced zero violations — the drift came from three previously-merged PRs (`memory-pressure-monitor.sh` assoc arrays from 2026-04-08, `pre-dispatch-validator-helper.sh` assoc array from 2026-04-15 via PR #19120). Runtime safety analysis showed `memory-pressure-monitor.sh` is the only one that genuinely needs fixing at runtime: `pre-dispatch-validator-helper.sh` already sources `shared-constants.sh` so the re-exec guard protects it; `memory-pressure-monitor.sh` does NOT and crashes under `/bin/bash` 3.2 on the first `${cmd_name,,}` case-conversion at line 465.

## What

Two orthogonal fixes to `.agents/scripts/memory-pressure-monitor.sh`:

1. **Scanner fix** — convert the two `local -A` PID→value maps to sparse `local -a` indexed arrays. PIDs are numeric, so indexed arrays are a drop-in replacement with identical semantics. Drops the scanner count 78 → 76 (back at threshold).
2. **Runtime fix** — add `source "${_MEMPRESS_DIR}/shared-constants.sh"` near the top so the framework's re-exec guard transparently upgrades `/bin/bash` 3.2 invocations to modern bash. This is required because the script uses `${cmd_name,,}` case conversion (bash 4+) at lines ~463-466 which the scanner does NOT detect but which crashes on 3.2 with `bad substitution`.

## Why

- Unblocks PR #19344 and every future PR from the same ratchet regression.
- Fixes a real runtime bug — the script currently fails on macOS `/bin/bash` 3.2 invocations even though it's registered as a launchd agent (which uses `/bin/bash`). Silent breakage that's only masked because users running `setup.sh` get `shared-constants.sh` auto-upgrades on scripts that source it.
- Parallel indexed arrays vs associative arrays are semantically identical for numeric keys — zero regression risk for bash 4+ users (Linux CI, upgraded macOS).

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** 1 file (`memory-pressure-monitor.sh`, 1340 lines). File >500 lines disqualifies tier:simple per the default list. The two array-type changes are near-mechanical; the new source block is a copy of the pattern already used by `pre-dispatch-validator-helper.sh:39`.

## PR Conventions

Leaf issue — uses `Resolves #19348`.

## How

### Files Modified

- `EDIT: .agents/scripts/memory-pressure-monitor.sh:65-67` — add re-exec guard source block right after `set -euo pipefail`
- `EDIT: .agents/scripts/memory-pressure-monitor.sh:417` — `local -A etime_map` → `local -a etime_map=()`
- `EDIT: .agents/scripts/memory-pressure-monitor.sh:526` — `local -A age_map` → `local -a age_map=()`

### Reference pattern

`pre-dispatch-validator-helper.sh:36-39` — canonical `SCRIPT_DIR` + `source shared-constants.sh` block.

### Verification

1. `shellcheck .agents/scripts/memory-pressure-monitor.sh` — clean ✓
2. `/bin/bash -n .agents/scripts/memory-pressure-monitor.sh` — parse check passes ✓
3. `/bin/bash .agents/scripts/memory-pressure-monitor.sh --status` — re-exec fires, full output renders ✓
4. `/opt/homebrew/bin/bash .agents/scripts/memory-pressure-monitor.sh --status` — direct run, full output ✓
5. `AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/memory-pressure-monitor.sh --status` — guard skipped, fails loudly at line 488 `${cmd_name,,}` as expected (opt-out behaves correctly) ✓
6. Local scanner run across the tree: `Total violations: 76` — exactly at threshold ✓

## Acceptance criteria

- [ ] Both `local -A` → `local -a` conversions applied
- [ ] Re-exec guard source block present at top of file
- [ ] Shellcheck clean
- [ ] `/bin/bash` smoke test succeeds (re-exec fires)
- [ ] CI `Bash 3.2 Compatibility` check passes (count ≤ 76)
- [ ] PR merged
- [ ] #19348 closed via `Resolves`

## Out of scope

- `pre-dispatch-validator-helper.sh:55` associative array — already protected by re-exec guard (it sources `shared-constants.sh`), low priority.
- Refactoring the `${var,,}` call sites to `tr '[:upper:]' '[:lower:]'` — not needed, re-exec guard handles this.
- Ratcheting the threshold 76 → 75 after this merge — tracked as a follow-up when the `pre-dispatch-validator-helper.sh` case is also cleaned.

Resolves #19348
