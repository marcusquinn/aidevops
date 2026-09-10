<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18424: Correlate objectives with verified outcomes and subagent repair

## What

Add privacy-safe objective/run attribution and explicit acceptance/rework observations to the existing runtime-event store. Connect a verified objective to its contributing root/child sessions and attempts without making telemetry a new task authority or interpreting a child finishing as accepted work.

## Why

Current request rows have parent-session linkage but no reliable objective boundary. `.agents/plugins/opencode-aidevops/observability.mjs:559` correctly records host completion while leaving acceptance, verification and rework unknown. Multi-objective sessions and repeated attempts therefore cannot yet supply fair cost-per-completion denominators.

## Origin

Created 2026-09-10 through interactive planning. Parent: t18422. Blocked by t18423 (`blocked-by:t18423`); retain auto-dispatch intent and native dependency blocking. Baseline: `f610e0abaabec36bc38f014f1f69a6fd44a49e88`; consume t18423's merged provenance contract before editing.

## Pre-flight

- [x] Memory recall: acceptance/telemetry/repair — no relevant hits.
- [x] Discovery pass: runtime-event ownership and merged context-efficiency work reviewed; zero related open PRs and no matching open implementation issue found.
- [x] File refs verified: event envelope/CLI/payload allowlist, append-only store, host outcome writer and tests inspected.
- [x] Tier: standard — event semantics, ownership, privacy and backward compatibility are decided below.
- [x] Seeded draft PR decision recorded: skipped until the prerequisite contract lands.

## Tier

**Selected tier:** `tier:standard`. No scheduler/dispatch-path change; this is optional observational evidence, not a completion/merge permission mechanism.

## How

### Files to Modify

- `EDIT: .agents/scripts/runtime-events.mjs` — envelope at line 71; extend the existing validated event path.
- `EDIT: .agents/scripts/runtime-events-cli.mjs` — explicit session attribution around line 45.
- `EDIT: .agents/scripts/runtime-events-payload.mjs` — bounded allowlist at line 25.
- `EDIT: .agents/scripts/runtime-events-store.mjs` — existing reader and append-only store.
- `NEW: .agents/scripts/runtime-events-objectives.mjs` — optional focused validation, following the existing event module pattern.
- `EDIT: .agents/plugins/opencode-aidevops/observability.mjs` — host contribution linkage at line 559.
- `EDIT: .agents/scripts/runtime-events-retention.mjs` — protect acceptance and attachment events.
- `EDIT: .agents/reference/observability.md` — contract documentation.
- `EDIT: .agents/reference/agent-routing.md` — optional terminal producer instruction.

### Files Scope

- `.agents/scripts/runtime-events.mjs`
- `.agents/scripts/runtime-events-cli.mjs`
- `.agents/scripts/runtime-events-payload.mjs`
- `.agents/scripts/runtime-events-store.mjs`
- `.agents/scripts/runtime-events-objectives.mjs`
- `.agents/scripts/runtime-events-retention.mjs`
- `.agents/plugins/opencode-aidevops/observability.mjs`
- `.agents/plugins/opencode-aidevops/observability-routing.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-runtime-events.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-observability-retention.mjs`
- `.agents/scripts/tests/test-runtime-events-cli.sh`
- `.agents/scripts/tests/test-observability-runtime-events.sh`
- `.agents/reference/observability.md`
- `.agents/reference/agent-routing.md`

### Complete Write Surface

- **Callers/readers:** `runtime-events-cli.mjs` emit/query/lineage and `observability.mjs` host callbacks; t18425 consumes the resulting evidence.
- **Writers/mutation paths:** `runtime-events.mjs` append helpers, explicit parent `emit` and existing host outcome recording; no change to task/merge authority.
- **Tests/fixtures:** `test-runtime-events.mjs`, `test-runtime-events-cli.sh`, `test-observability-runtime-events.sh`, routing-join and retention fixtures.
- **Schemas/config:** `runtime-events-payload.mjs` allowlist and versioned objective payload; keep the current append-only store, no second database.
- **Generated/deployed mirrors:** `setup.sh` remains deployment owner; generated agents and runtime configuration are unchanged.
- **Migrations/backfills:** `runtime-events-store.mjs` keeps additive compatibility; no raw-transcript scan or historical acceptance backfill.
- **Cleanup/rollback paths:** `runtime-events-retention.mjs` protects lifecycle evidence; revert code without deleting the original or correcting events.

### Implementation Steps

1. Define versioned `objective.started`, `objective.session.attached`, `objective.outcome` and `subagent.acceptance` observations using existing envelope IDs plus allowlisted opaque objective/run/attempt/contribution identifiers. Add a small focused validation module only if needed; retain the existing CLI entry point.
2. Objective attachment must support message/time boundaries within a multi-objective session. Never assign a whole session to several objectives and charge it repeatedly. Ambiguous/shared work remains explicitly unallocated; deterministic unique request IDs deduplicate observed contributions.
3. Outcomes distinguish verified, accepted-but-unverified, failed, cancelled, incomplete and unknown. Record evidence kind/fingerprint, observer/source, policy version and timestamp. Parent acceptance is a parent assertion; deterministic verification requires a matching check/receipt observation. A caller-supplied success word alone does not become machine-verified evidence.
4. Contribution outcomes distinguish accepted unchanged, accepted with repair, rejected, reused and unknown. Capture observed repair linkage and intervention counts, never invent human minutes or semantic success from tool exit/host finish. Preserve original observations and append corrections/supersession rather than rewriting history.
5. Extend `runtime-events.mjs emit` with explicit session attribution as needed (its current CLI lacks a session flag), validate bounded fields, and return a receipt that can be checked with `query`. Preserve fail-open legacy writes; strict validation/readback for this new evidence must reveal when recording was unavailable, not silently claim recorded success.
6. Add one optional terminal recording instruction in the owning reference: record only when the parent has acceptance evidence, once per contribution/objective, not every turn. Support headless lineage already supplied through event correlation/run IDs without modifying launch mechanics. Protect outcome/attachment events in retention and preserve private evidence outside Git.

### Hazards and Compatibility

- **Concurrency/atomicity:** Existing SQLite append semantics handle concurrent producers; preserve redaction and 16-KiB bounds.
- **Migration/rollback:** Additive fields/events only; rollback leaves observations unused rather than deleting them.
- **Mixed-version/backward compatibility:** Old/partial lineage and host-only receipts remain unknown until matching evidence arrives.
- **Idempotency/retry:** Duplicate IDs are idempotent; corrections append and retain conflicts, including child-before-parent ordering.
- **Partial failure/recovery:** Expose failed recording/readback without granting task/merge authority; preserve receipts and resume the same IDs.

### Verification Before Dispatch

```bash
node .agents/plugins/opencode-aidevops/tests/test-runtime-events.mjs
node .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs
node .agents/plugins/opencode-aidevops/tests/test-observability-retention.mjs
bash .agents/scripts/tests/test-runtime-events-cli.sh
bash .agents/scripts/tests/test-observability-runtime-events.sh
.agents/scripts/linters-local.sh --changed
```

Add focused fixtures for a root+child+repair chain, two objectives in one session, shared/unallocated work, duplicate/out-of-order/corrected observations, bare host-success, forged verification source, redaction and interrupted recording. Exercise `emit`→`query` on a disposable database. These commands are requirements, not claims of completed implementation testing.

- **Surface mapping:** Event/CLI tests prove payload validation and readback; routing join proves contribution identity; retention proves durable lifecycle evidence; changed-file lint covers all modified modules/references.

### Progressive Context Plan

Read the CLI/envelope/allowlist first, then the host outcome callback. Load retention only for new event preservation. Stop when each observation's owner, identity and fixture are clear; no full transcript discovery is needed.

## Acceptance Criteria

- [ ] An objective can be joined to uniquely bounded contributing requests, children and repair attempts using explicit evidence.
- [ ] Host completion and parent assertions cannot manufacture automated verification; missing/conflicting attribution is reported unknown/unallocated.
- [ ] Event replay and retention preserve one logical contribution without duplicate cost or loss of evidence; old consumers and permission/dispatch behaviour are unchanged.

## Recovery and Seeded Draft PR

No seed. Checkpoint after the disposable CLI path passes. If a fuse/lock fails, retain the objective and remaining criteria, resume the same IDs from the next safe append/readback, and never repair by dropping the production store.
