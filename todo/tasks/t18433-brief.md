<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18433: Integrate production objective outcomes and subagent repair evidence

## What

Complete the normal-work producer-to-report path for objective outcomes and subagent acceptance/repair. Eligible interactive and headless work must produce bounded, attributable evidence in the existing runtime-event store, and the existing efficiency scorecard must correctly join that evidence to actual request rows. Do not change model selection or reasoning defaults.

Automate mechanical identity, request-boundary capture and receipt persistence. Keep acceptance an explicit parent decision and independently verified completion a separate, evidence-backed observation. A completed child, successful tool invocation, merged PR, or lifecycle terminal marker alone must never manufacture semantic acceptance.

## Why

A model-tiering audit found active request recording but no usable outcome denominator. Without this integration, cheaper calls cannot be compared fairly with fewer retries, rejected contributions, parent repair, or accepted results. This is an instrumentation follow-up, not a routing experiment or a request for another dashboard.

### Verified prior delivery and remaining evidence

- Issue #31699 (t18424) is CLOSED; PR #31726 merged on 2026-09-10 at commit `1b9fd41d7c7789c6246078378e0fee90d84245a6`. It delivered objective-event validation/CLI support, an explicit acceptance API and optional recording guidance.
- Issue #31701 (t18425) is CLOSED; PR #31729 merged on 2026-09-10 at commit `3226532e2659b69f644a9aba99feda4a02845a79`. It delivered the objective-evidence report reader. Do not reopen or repeat either implementation. Their stale local TODO markers are corrected by this planning change.
- Aggregate local observation ending 2026-09-14 00:40 UTC: 28,746 request rows across 726 sessions and 237 `subagent.host.outcome` events over seven days, but zero `objective.*` or `subagent.acceptance` events. This means missing evidence, not zero successful work. No private session identities or paths are needed to reproduce the coverage query.
- The existing read-only `report-token-use-helper.sh efficiency --since 7d --json` runs and returns null verified-completion rate and cost per verified objective. The earlier audit passed 58 focused routing/event/pricing/subagent tests; passing interface tests did not establish production producer coverage.
- `.agents/plugins/opencode-aidevops/index.mjs:472-480` wires `onSubagentOutcome`, while `.agents/plugins/opencode-aidevops/observability.mjs:629-654` exposes explicit `recordSubagentAcceptance`. The host-outcome path is not acceptance.
- A second end-to-end hazard was reproduced during briefing: `.agents/scripts/report_token_objectives.py:36` makes attachment IDs strings, but `attached_request_rows` at lines 53-57 compares them with the production ledger's INTEGER primary key. The existing objective fixture at `.agents/scripts/tests/test_report_token_efficiency.py:74` uses a TEXT primary key instead. An in-memory production-shaped row with ID `1`, cost `1.5`, and attachment `"1"` reports one mapped/verified objective but zero attributable requests and cost `0.0`. Repair the identifier contract and missing-join semantics as part of making the producer-to-report path work.

## Pre-flight

- [x] Memory recall: `outcome repair recording integration` returned no hits; the preceding audit and source evidence are retained above.
- [x] Discovery pass: target history includes the two merged objective PRs and provenance PR #31721. Live searches found no open related PR for `objective`, and no open issues with `objective` or `outcome` in the title. Prior shipped work was inspected and excluded from the new scope.
- [x] File refs verified: cited implementation bodies and existing test paths were checked at baseline `ee7676f6ae1d53e21d46afb80fe9063c5fafad23`.
- [x] Tier: thinking; lifecycle/request attribution across parent, child, repair and resume needs synthesis. Counts and file sizes are not the tier decision.
- [x] Seeded draft PR decision recorded: skipped; this is a verified follow-up brief, not a speculative implementation seed.

## Origin

- **Created:** 2026-09-14, interactive OpenCode session; runtime session ID unavailable to this briefing command.
- **Created by:** ai-interactive, explicitly requested by the user after the metric audit.
- **Relationship:** standalone follow-up to #31699 and #31701; not blocked on those completed issues and not a replacement for them.
- **Execution intent:** worker-ready, auto-dispatch. Publication and deployment/release are not authorized by this brief. Existing model/provider/privacy/permission boundaries remain unchanged.
- **Conversation context:** the user prefers retaining the current model strategy and requested completion of the recording integration so future reviews can use evidence.

## Tier

**Selected tier:** `tier:thinking`.

The open decision is the smallest reliable binding between normal workflow objective boundaries, parent acceptance, independent check receipts and persisted request identity. Resolve that inside the constraints below; no new scheduler, completion authority or model-routing policy is required. Established mechanics should reuse existing implementations rather than expanding the design.

## How

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/index.mjs` — normal plugin wiring and an explicit parent decision entry point.
- `EDIT: .agents/plugins/opencode-aidevops/observability.mjs` — completed request capture, objective boundaries and contribution observations.
- `EDIT: .agents/plugins/opencode-aidevops/subagent-effort-escalation.mjs` — preserve child identities and carry objective/contribution context, not inferred acceptance.
- `EDIT: .agents/scripts/runtime-events.mjs` — reuse the append-only event/receipt API.
- `EDIT: .agents/scripts/runtime-events-cli.mjs` — bounded explicit decision receipts where needed by the normal integration.
- `EDIT: .agents/scripts/runtime-events-objectives.mjs` — preserve validation and document the identifier contract.
- `EDIT: .agents/scripts/report_token_objectives.py` — repair real-ledger identity joins and expose acceptance/repair coverage.
- `EDIT: .agents/scripts/report_token_efficiency.py` — retain unknown/partial estimates and surface the joined evidence.
- `EDIT: .agents/reference/agent-routing.md` — document the actual parent decision point, not another optional reminder alone.
- `EDIT: .agents/reference/observability.md` — document producer ownership, observers and unsupported/unknown cases.
- `EDIT: .agents/scripts/full-loop-helper-state-lifecycle.sh` — conditional integration seam: `save_state` at lines 68-122 already persists `run_id`, `state_revision`, phase attempts, terminal evidence and PR check head/evidence. Use that identity/evidence if applicable; it is not proof of semantic verification by itself. The exact small adapter design is not yet known, so trace this seam before editing rather than expanding the lifecycle file indiscriminately.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs` — exercise normal producer callbacks and the real ledger schema.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-runtime-events.mjs` — validation, receipts and replay.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs` — preserve host/parent distinction and child routing behavior.
- `EDIT: .agents/scripts/tests/test_report_token_efficiency.py` — replace the misleading schema assumption with production-shaped coverage.
- `EDIT: .agents/scripts/tests/test-runtime-events-cli.sh` — explicit decision append/readback without production writes.

These are allowed integration surfaces, not a requirement to edit every file. Do not introduce a separate test framework or benchmark harness. If a focused extracted adapter is necessary, establish its exact path and update the declared scope before writing it.

### Files Scope

- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/observability.mjs`
- `.agents/plugins/opencode-aidevops/subagent-effort-escalation.mjs`
- `.agents/scripts/runtime-events.mjs`
- `.agents/scripts/runtime-events-cli.mjs`
- `.agents/scripts/runtime-events-objectives.mjs`
- `.agents/scripts/report_token_objectives.py`
- `.agents/scripts/report_token_efficiency.py`
- `.agents/reference/agent-routing.md`
- `.agents/reference/observability.md`
- `.agents/scripts/full-loop-helper-state-lifecycle.sh`
- `.agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-runtime-events.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs`
- `.agents/scripts/tests/test_report_token_efficiency.py`
- `.agents/scripts/tests/test-runtime-events-cli.sh`

### Complete Write Surface

- **Callers/readers:** normal OpenCode interactive/headless plugin hooks, the selected existing workflow completion/verification seam, and the efficiency reader. `.agents/scripts/report-token-use-helper.sh` is the existing public report entry point; keep it compatible.
- **Writers/mutation paths:** `.agents/plugins/opencode-aidevops/observability.mjs` records requests and contributions; `.agents/scripts/runtime-events.mjs` and `.agents/scripts/runtime-events-cli.mjs` own event append/receipts. Capture real work and explicit parent/check decisions; do not seed synthetic production outcomes to make coverage nonzero.
- **Tests/fixtures:** `.agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs`, `.agents/plugins/opencode-aidevops/tests/test-runtime-events.mjs`, `.agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs`, `.agents/scripts/tests/test-runtime-events-cli.sh` and `.agents/scripts/tests/test_report_token_efficiency.py`. Exercise the real production SQLite schema/writer, not a simplified TEXT-ID substitute.
- **Schemas/config:** current versioned objective payload and request ledger. Define one unambiguous identifier contract across both and a compatible treatment for old evidence. No model routing-table, credential, account, permission or quota configuration changes.
- **Generated/deployed mirrors:** `setup.sh` owns deployment of source scripts/plugin files. Do not edit deployed copies or generated runtime configuration.
- **Migrations/backfills:** do not infer historical acceptance from transcripts, issue closure or host completion. Any additive compatibility work must retain original observations and explicitly identify unsupported legacy evidence.
- **Cleanup/rollback paths:** existing fail-open observational writers and protected append-only retention. Reverting producer code must not delete evidence, alter workflow outcomes or leave an authoritative shadow task state.

### Implementation Steps

1. Trace and document one normal interactive and one normal headless completion path. Bind an opaque objective/run identity to the contributing request boundaries at the existing owner. Capture child and parent repair contributions without charging a whole multi-objective session to every objective. Persist enough identity to survive resume/compaction and out-of-order child completion.
2. Resolve the reproduced identifier mismatch before trusting any reported cost. Use the actual ledger schema and writer to demonstrate that attachment IDs resolve to the intended rows. Prefer stable source-qualified identities; do not silently reinterpret old IDs or report a missing join as a genuinely zero-cost completion.
3. Emit `objective.started` and bounded `objective.session.attached` evidence from the normal path. Respect the current 128-ID attachment limit with idempotent batches. Shared, unresolved or conflicting ownership remains unallocated; preserve failed and incomplete attempts rather than retaining only the winning model's work.
4. Connect a low-friction, explicit parent acceptance action to `subagent.acceptance` for `accepted_unchanged`, `accepted_repaired`, `rejected`, `reused` or `unknown`. Persist the actual repair contribution linkage and observed intervention count. Mechanically collect context; do not parse a child's confident final prose as parent acceptance or invent human time.
5. Emit `objective.outcome` only from the matching completion decision/evidence. Independently verified outcomes need the existing observer, check/receipt kind, fingerprint, timestamp and policy version, tied to the applicable objective and code/artifact revision. Otherwise record accepted-unverified, failed, cancelled, incomplete or unknown as appropriate. A stop/merge marker or bare caller assertion is insufficient.
6. Make the existing efficiency report expose source-qualified objective and contribution/repair coverage and correctly attributable costs, including failed attempts where the metric contract requires them. Deduplicate contributions and retain null/partial results for missing joins or evidence. Do not label request-level routing attempts as complete worker-lease history.
7. Verify append/readback through the production-facing integration, not only direct manual `emit` calls. Exercise normal workflow callbacks against a disposable store without provider calls; after deployment use eligible real work and a bounded read-only coverage observation to confirm that the producer is active. Keep live observation explicitly pending if no eligible work occurs during the bounded window; do not fabricate it or change model defaults to generate traffic.

### Hazards and Compatibility

- **Concurrency/atomicity:** multiple sessions and out-of-order outcomes must not duplicate ownership or lose repair lineage. Reuse append-only storage and stable event/contribution identities; do not add a mutable parallel task authority.
- **Migration/rollback:** real INTEGER ledger IDs differ from the legacy TEXT fixture. Test both supported old evidence and production-shaped rows, with explicit unavailable results for unsupported or missing identity. Never rewrite historic costs or acceptance assertions.
- **Mixed-version/backward compatibility:** old sessions may lack objective boundaries, parent decisions or check receipts. Preserve unknown/partial coverage. Do not assume that a resolved effort label is provider-confirmed effort; changing effort/runtime provenance is outside this task.
- **Idempotency/retry:** resume, event replay, repeated terminal notifications and duplicate attachment batches count once. Corrected observations append with explicit supersession; reused contributions must not be charged again as new work.
- **Partial failure/recovery:** a telemetry failure must not fail or authorize the underlying code task, but must yield visible recording-unavailable evidence rather than a false success receipt. Never relax privacy, permissions or independent-verification requirements to fill the metrics.

### Complexity Impact

`save_state` is currently 55 lines and `_full_loop_append_event` is 16 lines. If that shell seam is selected, keep its adapter minimal and extract focused observational helpers before approaching the repository's function-complexity limits. The required amount of shell growth is not yet known; this brief does not authorize a broad lifecycle refactor.

### Progressive Context Plan

Read the existing event validation, `recordSubagentAcceptance`, normal child-hook wiring and objective reader first. Load lifecycle state only to establish the chosen normal-work identity/check seam. Stop discovery once producer ownership, the identifier contract, independent verification and focused acceptance checks are explicit. Broader task-coordinator and replay redesigns are out of scope.

### Verification Before Dispatch

The briefing audit ran existing interface tests and reproduced the INTEGER-ID join defect in an in-memory database. The new production integration is **UNVERIFIED** until implementation. Run these existing checks against the changed implementation:

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs .agents/plugins/opencode-aidevops/tests/test-runtime-events.mjs .agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs
PYTHONDONTWRITEBYTECODE=1 python3 .agents/scripts/tests/test_report_token_efficiency.py
bash .agents/scripts/tests/test-runtime-events-cli.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the Node suites cover plugin routing and runtime-event producers; the Python suite covers the actual request-to-objective cost join; the shell CLI suite covers explicit receipts and readback. Changed-file lint checks only the selected implementation surfaces; the following cases define their required coverage.
- Routing and event tests cover normal callbacks, parent/child/repair identity, real-schema append/readback, validation, privacy and replay.
- Efficiency tests must cover real INTEGER ledger identity, nonzero known costs, failed attempts, missing/conflicting attachments and unknown completion—not only the current TEXT-ID fixture.
- CLI tests cover bounded explicit decision receipts and query readback; they do not by themselves prove a normal producer is connected.
- Changed-file lint covers the selected source surfaces. If a lifecycle adapter changes shell behavior, add the narrow existing lifecycle checks applicable to that adapter; select the exact tests after resolving that conditional seam, not a repository-wide gate.
- For live observation, use the existing `report-token-use-helper.sh efficiency --since 24h --json` and aggregate event coverage only. Verify acceptance/repair evidence in addition to host-outcome counts. No paid synthetic jobs, raw transcript scraping or production fixture injection.

## Acceptance Criteria

- [ ] Normal interactive and headless integration paths produce attributable objective/request evidence and an explicit parent-acceptance receipt when such a decision actually occurs; proof is not limited to invoking an otherwise-unused helper manually.
- [ ] A production-schema root/child/repair fixture attributes known costs exactly once; the reproduced INTEGER-ID case no longer yields zero matched rows and a false zero-cost verified result. Missing/conflicting identities remain unavailable or explicitly partial.
- [ ] Parent acceptance and independent verification remain distinct. Child termination, command success, PR merge and missing/caller-only check evidence cannot mark an objective verified; failed/cancelled/incomplete work remains observable.
- [ ] Accepted-with-repair and rejected/reused contributions have correct source-qualified linkage and coverage in the existing report, including resume/out-of-order/duplicate handling without duplicate cost.
- [ ] Existing privacy, append-only retention, permission/merge authority, model defaults and historical records remain unchanged. The implementation summary distinguishes fixture proof, production-path proof and any pending live coverage observation.

## Safety-Stop Recovery

Preserve the objective/run/contribution identifiers, existing receipts, unmatched evidence and remaining criteria if a lock, timeout or safety gate stops recording. Resume the same bounded append/readback through the normal owner. Do not delete the store, relax validation, manufacture acceptance or re-run model work merely to obtain metrics.

## Seeded Draft PR

Skipped. Producer ownership and cross-session request boundaries need implementation-time synthesis; a speculative seed would anchor that decision prematurely. The follow-up issue is the implementation brief, not a claim that production recording is complete.
