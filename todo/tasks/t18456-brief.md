<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18456: Optional Jev batch adapter with authorized-runtime fallback

## Pre-flight

- [x] Memory recall: parent query returned no relevant lessons.
- [x] Discovery pass: PRs #32036/#32038/#32051 already shipped examples/pilots/evaluation; this adapter must reuse their boundaries.
- [x] File refs verified: Jev example/pilot/docs/tests and capability registry exist.
- [x] Tier: standard; existing privacy/transport boundaries are fixed; no new default provider or model-clone work.
- [x] Seeded draft PR skipped: contract and account registry predecessor must merge first.

## Origin

2026-09-20 OpenCode interactive background request. Parent: t18444. blocked-by:t18455. This serialization prevents concurrent capability-registry edits; shared core t18445 is a transitive prerequisite.

## What

Implement a separate opt-in Jev adapter for the common decision contract, with bounded requests, strict validation and an explicit fallback-required result to the already authorized runtime. Preserve existing synthetic/public pilot restrictions and all current defaults.

## Why

Allow a cheap decision backend without tying domain workflows to vendor access, assuming confidence calibration, or silently changing data policy.

## Tier

Selected tier: `tier:standard`; implement a decided adapter boundary using known transport patterns.

## How

### Files to Modify

- `NEW: .agents/scripts/marketing-decision-jev-helper.py` — explicit adapter CLI.
- `NEW: .agents/scripts/marketing_decision_jev.py` — provider transport and typed-answer validation.
- `EDIT: .agents/tools/ai-assistants/jev.md` — distinguish new opt-in adapter from preserved examples.
- `EDIT: .agents/tools/ai-assistants/jev-decisions.md` — pointer to shared domain workflow.
- `EDIT: .agents/configs/capability-registry.json` — narrow optional readiness entry.
- `NEW: .agents/scripts/tests/test-marketing-decision-jev.py` — mocked adapter contract tests.

Read `.agents/scripts/jev-example.py`, `.agents/scripts/jev-pilot.py`, `.agents/tools/ai-assistants/jev-pilots.md` and `.agents/reference/jev-research.md`. Verify current official model/API/terms and local version before use; no copy of external SDK code or guessed endpoints.

### Files Scope

- `.agents/scripts/marketing-decision-jev-helper.py`
- `.agents/scripts/marketing_decision_jev.py`
- `.agents/tools/ai-assistants/jev.md`
- `.agents/tools/ai-assistants/jev-decisions.md`
- `.agents/configs/capability-registry.json`
- `.agents/reference/capability-registry.md`
- `.agents/scripts/tests/test-marketing-decision-jev.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/jev-request.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/jev-response.json`

### Complete Write Surface

- **Callers/readers:** shared `.agents/scripts/marketing_decisions.py` adapter interface and Jev leaf documentation.
- **Writers/mutation paths:** `.agents/scripts/marketing_decision_jev.py` writes private results, sends only explicitly approved bounded payloads.
- **Tests/fixtures:** new adapter tests plus existing `.agents/scripts/tests/test-jev-example.py` and test-jev-pilot.py.
- **Schemas/config:** consume shared decisions; optional readiness entry in `.agents/configs/capability-registry.json`.
- **Generated/deployed mirrors:** regenerate `.agents/reference/capability-registry.md` with existing tooling if required; no deployed runtime/default routing edits.
- **Migrations/backfills:** N/A because existing pilots/journal and model mappings are not migrated or relaxed.
- **Cleanup/rollback paths:** remove `.agents/scripts/marketing_decision_jev.py` and its registry entry; restore docs, keeping the approved runtime route.

### Implementation Steps

1. Provide `decide --input FILE --dry-run` without credentials/network. Live requires explicit provider/data authority plus readiness and a bounded budget; key presence alone is insufficient. Default examples remain synthetic/non-personal public material.
2. Translate atomic choices/scores/yes probabilities and independent same-state questions, preserving unknown/multi-label semantics. Pin model/rubric, reject malformed probabilities/unknown options/model drift, and keep score versus distribution confidence distinct.
3. Bound batch/concurrency/timeout/bytes, validate fixed provider endpoints, reject redirects, handle 429/cooldowns, and never retry auth failures blindly. No model-produced URLs/code/actions are executed.
4. Missing/disallowed/unavailable Jev returns explicit fallback-required with preserved evidence. Host may invoke its existing approved route only inside unchanged billing/data/cancellation limits; report whether fallback actually ran. No new global model mapping, compaction/continuation hook, cloning, distillation or training labels.
5. Add optional evaluation hooks to t18454's evidence contract, not public benchmarks or broad telemetry. Do not reuse illustrative pilot confidence cutoffs as calibrated production thresholds.

### Hazards and Compatibility

- **Concurrency/atomicity:** enforce per-batch budget/cancellation and shared private writes without leaking account state.
- **Migration/rollback:** optional entry removal restores current behavior; existing pilot restrictions stay unchanged.
- **Mixed-version/backward compatibility:** reject model/schema drift and preserve established runtime behavior.
- **Idempotency/retry:** bounded retry/cooldown only; no duplicate charged requests after unknown completion without evidence.
- **Partial failure/recovery:** retain results/failures and unresolved rows; permission/privacy/budget stops cannot be bypassed by fallback.

### Verification Before Dispatch

```bash
python3 .agents/scripts/marketing-decision-jev-helper.py decide --input .agents/scripts/tests/fixtures/marketing-decisions/jev-request.json --dry-run
python3 .agents/scripts/tests/test-marketing-decision-jev.py
python3 .agents/scripts/tests/test-jev-example.py
python3 .agents/scripts/tests/test-jev-pilot.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** dry-run proves no key/network; mocked tests cover typed mapping, invalid response, drift, cooldown and fallback status; existing tests protect pilots. Registry checks apply if changed.
- **Recoverability:** checkpoint focused verified work; provider unavailability does not block offline delivery. Keep any live validation explicitly unavailable until separately authorized, with no secret request in chat.

## Acceptance Criteria

- [ ] Synthetic/mock Jev decisions map correctly to the shared schema and preserve unknowns, multi-label cases and confidence provenance.
- [ ] Missing access, malformed outputs and privacy/budget/cancellation blocks produce safe explicit fallback-required status, never unauthorized transmission or claimed fallback execution.
- [ ] Existing examples, pilots, runtime model defaults and private evaluation restrictions remain unchanged.
