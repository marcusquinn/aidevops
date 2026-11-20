<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t19132: perf(pulse-dispatch): PR-evidence negative-cache hints outlive one pulse cycle so blocked candidates skip the dedup ceremony

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `negative cache ttl dedup_pr_evidence` → 0 hits
- [x] Discovery pass: #32580 set the 1800s general TTL cap; GH#38142 added owner-independent PR-evidence hints; no open PR touches `_dispatch_pr_evidence_hint_valid`
- [x] File refs verified: `.agents/scripts/pulse-dispatch-lib.sh` `_dispatch_negative_cache_reason`, `_dispatch_pr_evidence_hint_valid`; `.agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh` PR-evidence case
- [x] Tier: `tier:standard` — per-reason TTL override matching existing pattern
- [x] Seeded draft PR decision recorded: skipped — implemented interactively

## Origin

- **Created:** 2026-11-19
- **Session:** opencode:interactive-2026-11-19 (pulse/worker throughput mission)
- **Created by:** ai-interactive (unattended mission authorised by maintainer)
- **Conversation context:** `dispatch-stages.tsv` showed most of each dispatch cycle spent on dedup checks for candidates that could not launch; the cross-cycle cache rarely hit.

## What

`dedup_pr_evidence` negative-cache hints use their own TTL (`AIDEVOPS_DISPATCH_PR_EVIDENCE_CACHE_TTL_SECONDS`, default 7200, cap 14400) instead of the 1800s general TTL, so a hint written in one pulse cycle is still valid in the next.

## Why

Pulse cycles now run longer than the 1800s general TTL (24 cycles to 2026-11-19T04:47Z: median 2329s, p90 5030s). A PR-evidence hint therefore expired before the next cycle could use it:

- Since `pulse.log` line 380k: 61 full-ceremony `DISPATCH_BLOCK_REASON reason=dedup_pr_evidence` blocks across 11 repeat issues, against 3 `cross-cycle block:dedup_pr_evidence` hits. `terminal_blocker_circuit`, with a 7200s TTL, hit 16 times from 6 records.
- Cycle `20261119T045105Z-39204`: `dedup.dedup_check` n=46 at 26.8s average for 8 launches.

The hint stays safe at a longer TTL because every hit still requires an unchanged issue `updatedAt` and an unchanged exact-PR fingerprint (state, draft, merged_at, updated_at, head SHA) from a fresh REST read. A failed read is a miss.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-lib.sh` — new `_DISPATCH_PR_EVIDENCE_CACHE_TTL_SECONDS` beside the other per-reason TTLs; the `dedup_pr_evidence` branch of `_dispatch_negative_cache_reason` uses it.
- `EDIT: .agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh` — a 3600s-old hint is a hit; a hint at the TTL is a miss.

### Hazards

- Hints stay skip-only. Validation order is unchanged: the issue revision gate, then TTL, then the PR fingerprint read.
- Active-claim reasons keep the 1800s TTL because claims expire on a clock.

## Acceptance Criteria

- [x] `bash .agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh` passes. The new case fails with `AIDEVOPS_DISPATCH_PR_EVIDENCE_CACHE_TTL_SECONDS=1800`.
- [x] `bash .agents/scripts/tests/test-pulse-dispatch-negative-cache-material.sh` passes (18/0).
- [x] ShellCheck clean on both files.
- [ ] After deploy, `cross-cycle block:dedup_pr_evidence` hits rise over consecutive cycles, and per-cycle `dedup.dedup_check` counts fall.

## Relevant Files

- `.agents/scripts/pulse-dispatch-lib.sh` — `_dispatch_negative_cache_reason`, `_dispatch_pr_evidence_hint_valid`
- `.agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh` — PR-evidence hint case
