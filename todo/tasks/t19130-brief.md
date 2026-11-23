<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t19130: fix(pulse-merge): stale non-required pending checks are ignored when required contexts are skipped, so path-filtered PRs stop starving the merge pass

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `stale non-required pending check merge pass skipped required context` → 0 hits
- [x] Discovery pass: GH#38834 (merged) added the stale non-required pending ignore; no open PR touches `_pmrc_stale_pending_age`
- [x] File refs verified: `.agents/scripts/pulse-merge-required-checks.sh` `_pmrc_stale_pending_age`, `_pmrc_snapshot_checks_acceptable`; `.agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh` `assert_stale_pending_checks`
- [x] Tier: `tier:standard` — one-predicate change matching an existing pattern
- [x] Seeded draft PR decision recorded: skipped — implemented interactively

## Origin

- **Created:** 2026-11-19
- **Session:** opencode:interactive-2026-11-19 (pulse/worker throughput mission)
- **Created by:** ai-interactive (unattended mission authorised by maintainer)
- **Conversation context:** `deterministic_merge_pass timing` for marcusquinn/aidevops showed `merged=0` and `graceful time budget exhausted` across consecutive passes, with Issue Sync PR #39090 the slowest PR (114-349s) in 6 of them.

## What

The pre-merge snapshot ignores a non-required check run that has been pending longer than `PULSE_MERGE_STALE_NONREQUIRED_PENDING_SECONDS` (default 3600) when every required context is completed with `success`, `neutral` or `skipped`.

## Why

`_pmrc_stale_pending_age` required `.conclusion == "success"` for every required context. TODO-only PRs skip path-filtered required workflows (`Framework Validation`, `Complexity Analysis`), which GitHub branch protection and the rest of the snapshot treat as passing. PR #39090 has those two `skipped`, the rest `success`, and `CodeFactor` hung `in_progress` since 2026-11-18T23:10Z, so every merge pass re-evaluated and refused it, spending most of its ~186s budget there and leaving other green PRs unmerged.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge-required-checks.sh` — `_pmrc_stale_pending_age` precondition accepts `success`, `neutral`, `skipped` (completed status still required).
- `EDIT: .agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh` — `assert_stale_pending_checks` adds a skipped-required case.

### Hazards

- Required contexts that are pending, failed, cancelled or missing still fail closed. Normalization keeps the latest executed result per context, so a skipped rerun cannot hide a failed run.

## Acceptance Criteria

- [x] `bash .agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh` passes (132/0); the new case fails without the fix.
- [x] ShellCheck clean on both files.
- [ ] After deploy, the merge pass logs `IGNORED stale non-required pending check 'CodeFactor'` for PR #39090 and merges it.

## Relevant Files

- `.agents/scripts/pulse-merge-required-checks.sh` — `_pmrc_stale_pending_age`, `_pmrc_pending_is_ignored`, `_pmrc_snapshot_checks_acceptable`
- `.agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh` — `assert_stale_pending_checks`
