<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18093: Record runtime safety Qlty baseline

## Pre-flight

- [x] Memory recall: issue #27030 security-contract implementation and Qlty gate outcome
- [x] Discovery pass: PR #27063 merged before the absolute threshold repair; main contains 84 smells against threshold 56
- [x] File refs verified: `.agents/configs/complexity-thresholds.conf` and history audit trail
- [x] Tier: `tier:simple` — deterministic post-merge CI repair
- [x] Seeded draft PR decision recorded: skipped — two-file threshold/history correction already verified

## Origin

- **Created:** 2026-07-11
- **Session:** OpenCode interactive follow-up to PR #27063
- **Created by:** ai-interactive
- **Parent task:** t18085 / GH#27030
- **Blocked by:** none
- **Conversation context:** The runtime-neutral safety PR introduced 28 measured Qlty smells in exhaustive fail-closed parsers/state machines. Its justified threshold update missed the auto-merge.

## What

Record the measured 84-smell state with two units of headroom and an auditable history entry so the absolute Qlty threshold reflects merged main. Preserve automatic ratchet-down behavior.

## Why

Without this correction, main's absolute Qlty gate fails despite the per-PR/new-file overrides and passing security, concurrency, reconstruction, and diff-scoped complexity gates.

## How

- Set `QLTY_SMELL_THRESHOLD=86` with the GH#27030/PR #27063 rationale.
- Add the matching history row.
- Verify the threshold helper, its unit tests, and changed-file linters.

## Acceptance

- [x] `qlty-smell-threshold-helper.sh` reports 84/86 with two units of headroom.
- [x] Threshold history records why the temporary increase is justified.
- [x] Ratchet-down automation remains unchanged.
- [x] Threshold helper tests and changed-file linters pass.

## Context and Constraints

- Ref #27030 and PR #27063; do not re-resolve the already closed issue.
- This records measured debt rather than excluding files or disabling rules.
- Focused simplification should reduce the threshold in later smell-reducing merges.
