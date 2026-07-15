<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18130: Invalidate canonical GitHub state from verified webhooks

Parent: t18124

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `GitHub webhook cache invalidation delivery dedup HMAC canonical state` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 2 related target-file commits / 0 overlapping open PRs; existing receiver validates HMAC but has no delivery ledger or canonical cache invalidation
- [x] File refs verified: 6 source/config/test surfaces checked, all present at `313548fc6` or verified new-file parents
- [x] Tier: `tier:thinking` — security-sensitive event mapping, replay defense, concurrency, and fallback polling require design judgment
- [x] Seeded draft PR decision recorded: skipped — blocked until t18129 supplies stable shared invalidation and coordination interfaces

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive GitHub API efficiency planning
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18124
- **Blocked by:** t18129 through a native GitHub blocked-by relationship
- **Conversation context:** The current loopback webhook server validates `X-Hub-Signature-256`, reads `X-GitHub-Delivery`, and triggers selected PR processing. It does not deduplicate deliveries or invalidate issue/PR/check caches, so bounded polling remains the only cache freshness signal.

## What

Extend the existing receiver with a versioned, bounded delivery ledger and a typed invalidation action protocol. After HMAC validation, map supported issue, PR, review, check-suite/check-run, and status events to the narrowest canonical snapshot or head-SHA check cache keys; invalidate before triggering PR processing. Keep loopback binding, bounded payload/concurrency, and polling/TTL as a recovery backstop.

## Why

Longer cache TTLs save requests but increase stale-state risk unless changes can invalidate state promptly. GitHub redelivers webhooks and may deliver events out of order, so blindly processing every delivery can cause duplicate refresh bursts. A signed event is a freshness hint, not final authority: invalidation should make the next reader refresh while final dispatch/merge gates still fetch exact current evidence.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — Python server, shell dispatcher, config, two cache providers, and tests coordinate.
- [ ] **Every target file under 500 lines?** No — canonical cache helpers may exceed 500 lines.
- [ ] **Exact oldString/newString for every edit?** No — event-to-key mapping and ledger protocol require design.
- [ ] **No judgment or design decisions?** No — security and freshness boundaries are architectural.
- [ ] **No error handling or fallback logic to design?** No — replay, out-of-order, malformed, write-failed, and receiver-down paths are core behavior.
- [ ] **No cross-package or cross-module changes?** No — Python, shell, config, cache modules, and tests interact.
- [ ] **Estimate 1h or less?** No — estimated two hours.
- [ ] **4 or fewer acceptance criteria?** No — HMAC, dedup, mapping, concurrency, and fallback each need proof.
- [x] **Dispatch-path classification:** Targets do not match `.agents/configs/self-hosting-files.conf`; normal auto-dispatch is permitted.

**Selected tier:** `tier:thinking`

**Tier rationale:** The receiver is an external input boundary. Correctness depends on authenticating before persistence/action, deduplicating atomically, and treating events as invalidation hints rather than authority.

## PR Conventions

Leaf task. The implementation PR closes only this issue and references parent t18124 without closing it.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Event actions must target the final snapshot/check cache keys and single-flight APIs produced by t18129.
- **Status:** `blocked`
- **Freshness evidence:** Receiver/server/config and cache invalidation candidates were checked at `313548fc6`.
- **Verification run:** Brief readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-check any webhook, cache-key, or final merge changes before defining event mappings.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-merge-webhook-server.py:26-70,82-133,136-186` — current event parser, HMAC gate, delivery header, and action output.
- **Then read:** `.agents/scripts/pulse-merge-webhook-receiver.sh:51-118,159-242` and `.agents/configs/webhook-receiver.conf` — secret loading, loopback dispatch, concurrency, and polling backstop.
- **Then read:** t18127–t18129 merged snapshot/check/single-flight invalidation APIs — use their exact keys rather than parsing cache filenames independently.
- **Load only if:** public exposure or deployment changes — use `.agents/workflows/public-launch-checklist.md`; no exposure change is required for this task.
- **Why:** Authentication, delivery deduplication, invalidation, and action dispatch must occur in that order.
- **Stop when:** fixtures prove one invalidation per signed delivery, duplicate replays make no writes/actions, and receiver failure falls back to polling.

### Worker Quick-Start

```bash
rg -n 'X-Hub-Signature-256|X-GitHub-Delivery|HANDLED_EVENTS|PROCESS_PR|process_pr' .agents/scripts/pulse-merge-webhook-server.py .agents/scripts/pulse-merge-webhook-receiver.sh
rg -n 'invalidate|evict|cache.*key|single.flight' .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/shared-gh-wrappers-checks.sh .agents/scripts/shared-gh-request-state.sh
```

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge-webhook-server.py:26-70,82-133,136-186` — validate delivery IDs, deduplicate signed deliveries, map events, and emit typed invalidation/action records.
- `EDIT: .agents/scripts/pulse-merge-webhook-receiver.sh:51-118,159-242` — configure private ledger, execute cache invalidation before `process_pr`, and preserve bounded concurrency/backstop behavior.
- `EDIT: .agents/configs/webhook-receiver.conf` — add handled events, ledger path/TTL/size, and invalidation controls with safe defaults.
- `EDIT: .agents/scripts/pulse-batch-prefetch-helper.sh` — expose idempotent repository collection invalidation using canonical keys.
- `EDIT: .agents/scripts/shared-gh-wrappers-checks.sh` — expose idempotent slug/head-SHA check invalidation.
- `NEW: .agents/scripts/tests/test-pulse-merge-webhook-invalidation.py` — signed fixture server tests for mapping, replay, order, limits, and invalidation protocol.

### Complete Write Surface

- **Callers/readers:** GitHub/tunnel posts to the loopback server; Python reads headers/body and emits typed records; shell reads records, invokes canonical invalidators, then optionally calls `process_pr`.
- **Writers/mutation paths:** `.agents/scripts/pulse-merge-webhook-server.py` writes only validated delivery metadata; canonical invalidators delete/tombstone exact keys and `.agents/scripts/pulse-merge-webhook-receiver.sh` keeps logs metadata-only.
- **Tests/fixtures:** `.agents/scripts/tests/test-pulse-merge-webhook-invalidation.py` sends local signed/unsigned issue, PR, review, check, status, duplicate, malformed, oversized, and out-of-order payloads.
- **Schemas/config:** `.agents/configs/webhook-receiver.conf` versions/configures the line protocol, ledger TTL/max/path, event list, body limit, host, port, and concurrency with loopback/bounded defaults.
- **Generated/deployed mirrors:** `.agents/scripts/pulse-merge-webhook-server.py` and `.agents/configs/webhook-receiver.conf` deploy through setup; secret and runtime ledger/log/cache remain private.
- **Migrations/backfills:** `.agents/configs/webhook-receiver.conf` remains compatible through defaults; no historical delivery backfill occurs and first run starts an empty bounded ledger.
- **Cleanup/rollback paths:** Disabling `.agents/scripts/pulse-merge-webhook-receiver.sh` retains bounded polling; ledger/cache deletion is safe and rollback never disables final live merge gates.

### Implementation Steps

1. Keep body-size and constant-time HMAC validation before JSON parsing, ledger writes, logs containing event metadata, invalidation, or process dispatch. Reject missing/malformed delivery IDs after authentication.
2. Implement a private atomic ledger keyed by delivery ID with schema version, received timestamp, event, and outcome. Bound by TTL and maximum entries; duplicate signed deliveries return success without repeated invalidation or action.
3. Emit a strict versioned protocol such as invalidation records plus existing PR actions. Validate slug, positive numeric IDs, full SHA format where present, and known event/action enums; never emit payload text.
4. Map issue mutations/comments to issue collection invalidation; PR open/sync/edit/label/review/close mutations to PR collection invalidation; check-suite/check-run/status changes to exact head-SHA check invalidation when SHA is available. Unknown/narrowly unmappable events invalidate only the relevant collection, not every repository cache.
5. In the shell receiver, apply idempotent invalidation before spawning `process_pr`. Let t18129 single-flight coalesce concurrent refreshes after bursts.
6. Preserve loopback default, HMAC secret handling, max body, concurrency cap, health endpoint, and periodic polling/TTL fallback. Webhook success never substitutes for final current-head required-check/merge verification.

### Hazards and Compatibility

- **Concurrency/atomicity:** Simultaneous duplicate deliveries require atomic first-writer ownership. Ledger cleanup cannot erase a newly inserted record, and invalidation racing a cache write must use generation/tombstone semantics or cause a safe subsequent miss.
- **Migration/rollback:** New events/config fields are additive. Disabling or reverting the receiver leaves polling active; no cache is trusted indefinitely because TTL remains.
- **Mixed-version/backward compatibility:** Existing `PROCESS_PR` records remain accepted during rollout; versioned new records are rejected safely by old consumers or rollout updates server/receiver atomically in one PR.
- **Idempotency/retry:** Duplicate delivery, repeated invalidation, and out-of-order older events are safe. A failed invalidation is logged and the target is not falsely marked fresh; polling repairs it.
- **Partial failure/recovery:** If ledger write fails, do not acknowledge/process as durably deduplicated unless the protocol deliberately falls back to at-least-once with bounded single-flight. If invalidation fails, preserve polling and avoid repeated comment/label writes.
- **Security/external content:** Payload fields are data only. Never execute commands, fetch URLs, log secrets/payload bodies, or let repository-controlled text enter the action protocol.

### Complexity Impact

- **Target functions:** `WebhookHandler.do_POST`, `_prs_from_event`, and `cmd_run`.
- **Current line count:** `do_POST` is about 39 lines; `cmd_run` is about 84 lines and near the shell complexity limit.
- **Estimated growth:** More than 120 lines across Python helpers, shell adapter, and tests.
- **Projected post-change:** Inlining invalidation parsing into `cmd_run` would exceed safe complexity.
- **Action required:** Add focused Python event/ledger helpers and a small shell record dispatcher; keep `cmd_run` orchestration-only.

### Verification Before Dispatch

```bash
python3 .agents/scripts/tests/test-pulse-merge-webhook-invalidation.py
shellcheck .agents/scripts/pulse-merge-webhook-receiver.sh .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/shared-gh-wrappers-checks.sh
python3 -m py_compile .agents/scripts/pulse-merge-webhook-server.py .agents/scripts/tests/test-pulse-merge-webhook-invalidation.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Python fixtures prove HMAC/delivery/event/ledger behavior; shell stubs prove invalidation-before-action and bounded recovery; compilation/ShellCheck/changed lint cover language and repository gates.
- **Broad verification trigger:** Required because this is an external input and merge-trigger path; run normal required CI plus security-focused review after the WIP checkpoint.

### Recoverability Checkpoint

- [ ] Focused tests pass: Python invalidation fixtures, py_compile, and shellcheck
- [ ] WIP commit created before broad gates: `wip: invalidate GitHub caches from webhooks`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Use authenticated webhooks to invalidate canonical GitHub state without weakening freshness or merge authority.
- **Preserved user directions:** Keep polling as a backstop and reduce request bursts through prior single-flight work.
- **Trigger and evidence:** Not triggered at brief creation.
- **Completed and verified:** Existing HMAC, delivery-header, event, and dispatch flow identified.
- **Remaining acceptance criteria:** All implementation, security, and canary criteria below.
- **Unsafe route not to repeat:** Do not persist or act before signature validation, and do not treat webhook payloads as merge authority.
- **Next safe route:** Build local signed fixture tests and ledger atomics before connecting cache invalidators.
- **Resume condition:** t18129 is closed and shared invalidation/single-flight interfaces are stable.
- **Owner and status:** Build+ `tier:thinking`; blocked by t18129.

### Files Scope

- `.agents/scripts/pulse-merge-webhook-server.py`
- `.agents/scripts/pulse-merge-webhook-receiver.sh`
- `.agents/configs/webhook-receiver.conf`
- `.agents/scripts/pulse-batch-prefetch-helper.sh`
- `.agents/scripts/shared-gh-wrappers-checks.sh`
- `.agents/scripts/shared-gh-request-state.sh`
- `.agents/scripts/tests/test-pulse-merge-webhook-invalidation.py`

## Acceptance Criteria

- [ ] Only payloads with valid HMAC, valid bounded body, supported event, valid slug/IDs, and a usable delivery ID can write the ledger or emit invalidation/action records.
- [ ] Replaying the same signed delivery produces no duplicate invalidation, refresh, process dispatch, comment, or label write.
- [ ] Supported issue/PR/review/check/status events invalidate only the narrowest canonical collection or exact head-SHA check key before any PR processing action.
- [ ] Ledger writes/cleanup and cache invalidation are atomic under concurrent and out-of-order deliveries; failure remains recoverable through TTL/polling.
- [ ] Loopback binding, secret isolation, payload/log privacy, body limit, concurrency cap, health check, and periodic polling backstop remain intact.
- [ ] Final dispatch, required-check, review, and merge decisions still obtain current authoritative evidence and never trust webhook payload data directly.
- [ ] Focused tests, security review, changed lint, required CI, and t18125 telemetry show lower polling latency/attempts before t18131 is promoted.

## Context & Decisions

- Webhooks are authenticated invalidation hints, not positive authority.
- Delivery ID deduplication occurs only after HMAC validation.
- Polling and TTL remain mandatory recovery paths for missed or disabled webhooks.

## Relevant Files

- `.agents/scripts/pulse-merge-webhook-server.py:26-70,82-133,136-186` — HMAC/event/action flow and unused delivery identity.
- `.agents/scripts/pulse-merge-webhook-receiver.sh:51-118,159-242` — secret/config loading and process dispatch loop.
- `.agents/configs/webhook-receiver.conf` — existing receiver defaults.
- `.agents/scripts/pulse-batch-prefetch-helper.sh` — canonical collection invalidation target.
- `.agents/scripts/shared-gh-wrappers-checks.sh` — head-SHA check invalidation target.

## Dependencies

- **Blocked by:** t18129.
- **Blocks:** t18131.
- **External:** Existing GitHub webhook delivery and configured secret; no new public endpoint or paid service.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Security/design | 30m | Event map, ledger, action ordering |
| Implementation | 60m | Server, receiver, config, invalidators |
| Tests/canary | 30m | Signed replay/concurrency fixtures |
| **Total** | **2h** | |
