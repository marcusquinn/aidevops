---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Linter resource safety

Use this reference when measuring or changing lint execution profiles across a
large repository or several repositories.

## Measurement contract

1. Establish the exact changed, affected, or full coverage boundary before
   comparing resource profiles.
2. Hash a normalized file or task inventory. Compare performance only when the
   before and after coverage boundaries are equivalent.
3. Run one benchmark at a time. Start concurrency at 1 and increase it only
   when the current profile completes within the resource contract.
4. Apply one total deadline to discovery, setup, and lint execution. A timeout
   exits non-zero and is never cached as success.
5. Sample aggregate process-tree CPU, RSS, and process count. Record thermal,
   available-memory, and swap state without publishing raw process details.
6. Terminate the complete process tree on timeout, pressure, or instability.
   Verify that descendants are gone before continuing.

## Recoverability

A fuse stops the unsafe route, not the objective. At the checkpoint, record:

- the trigger and last durable evidence;
- completed and remaining acceptance criteria;
- the unsafe route that must not be repeated unchanged;
- the next smaller shard, missing prerequisite, or safer execution profile;
- the condition that permits resumption.

Resume through a materially changed route, such as package-level shards,
reduced concurrency, generated prerequisites, or a narrower authoritative
boundary. Follow `.agents/reference/safety-stop-recovery.md` for the general
terminal-state rules.

## Decision rules

- Never compare wall time across different coverage digests.
- Treat a killed or timed-out profile as incomplete, not as a slow successful
  baseline.
- Retain a performance optimisation only when coverage is unchanged and its
  measured benefit meets the mission threshold without unacceptable regression.
- A lower-risk default may be retained as a safety guardrail when it completes
  the required coverage and is described without an unsupported performance
  claim.
- Similar CI gates are not duplicates when they preserve platform independence,
  trust-boundary separation, or distinct negative fixtures.

## Publication

Publish aggregate durations, peak resources, process counts, coverage digests,
decisions, confidence, and rollback instructions. Keep private repository names,
paths, source, command output, process details, and raw diagnostics local.
