<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18445: Shared marketing decision contract and bounded batch runner

## Pre-flight

- [x] Memory recall: `Jev SEO GEO marketing decision` returned no relevant lessons.
- [x] Discovery pass: current source `f85c65460`; merged PRs #32036/#32038/#32051 cover examples, pilots and evaluation, not this production-neutral contract; no related open PR found.
- [x] File refs verified: Jev docs/scripts, marketing optimization entry point and existing Python tests exist; proposed paths below are NEW.
- [x] Tier: thinking; cross-workflow schema, cache identity, partial-failure and provider boundaries require synthesis.
- [x] Seeded draft PR skipped: planning only, no implementation seed.

## Origin

2026-09-20 OpenCode interactive; maintainer requests background implementation. Parent: t18444. No dependency. Account/provider activation is not authorized by this brief.

## What

Deliver a provider-neutral, offline-first decision contract and bounded runner reused by ads, SEO/GEO and creative workflows. Export importable Python primitives and a small CLI; do not replace existing host model routing or the marketing performance store.

## Why

Avoid repeated full-context agents, inconsistent confidence handling and duplicated caching/measurement. This is a capability foundation, not a claim of measured efficiency.

## Tier

Selected tier: `tier:thinking`. Resolve cross-component evidence identity and restart/failure semantics; ordinary domain leaves subsequently use standard.

## How

### Files to Modify

- `NEW: .agents/scripts/marketing_decisions.py` — shared contract and runner; companion paths below.

NEW `.agents/scripts/marketing_decisions.py`, `.agents/scripts/marketing-decision-helper.py`, `.agents/configs/marketing-decision.schema.json`, `.agents/workflows/marketing-decisions.md` and focused tests/fixtures. Reference `.agents/scripts/jev-pilot.py`, `.agents/scripts/jev-evaluation.py`, `.agents/scripts/marketing_optimization_contract.py` and `.agents/tools/ai-assistants/jev-decisions.md` without relaxing their restrictions.

### Files Scope

- `.agents/scripts/marketing_decisions.py`
- `.agents/scripts/marketing-decision-helper.py`
- `.agents/configs/marketing-decision.schema.json`
- `.agents/workflows/marketing-decisions.md`
- `.agents/scripts/tests/test-marketing-decisions.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/core-valid.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/core-decisions.json`

### Complete Write Surface

- **Callers/readers:** domain CLIs in t18444 consume `.agents/scripts/marketing_decisions.py`.
- **Writers/mutation paths:** `.agents/scripts/marketing-decision-helper.py` writes only explicit private decision/cache artifacts; never accounts.
- **Tests/fixtures:** `.agents/scripts/tests/test-marketing-decisions.py` and `fixtures/marketing-decisions/core*` exercise the new contract.
- **Schemas/config:** `.agents/configs/marketing-decision.schema.json` is owned here, with versioning in `.agents/workflows/marketing-decisions.md`.
- **Generated/deployed mirrors:** normal `setup.sh` deployment only; no deployed files or runtime hooks are edited.
- **Migrations/backfills:** N/A because new opt-in artifacts have no legacy migration; existing marketing/Jev stores remain untouched.
- **Cleanup/rollback paths:** remove `.agents/scripts/marketing_decisions.py` and new companions; private evidence retention remains operator-owned, never silently deleted.

### Implementation Steps

1. Define versioned records for account/site scope, opaque row/candidate IDs, source IDs/spans, captured/as-of/window values, data classification, input digest, rubric/model/provider version, decision kind (choice, score, multi-label), value, reported probability/confidence and calibration provenance, abstention reason, action proposal, latency/usage/cost and unknown values. A score is not a probability; missing cost is null, not zero.
2. Preserve input and provenance; validate selections against observed candidate IDs, allow none/unknown, bound bytes/rows/candidates/concurrency, retain all failed/deferred rows. Scripts do arithmetic, not semantic policy.
3. Use project/account-isolated private storage and content/rubric/model/time-window-aware cache keys. Design atomic create/replay, cancellation/checkpoint and recovery semantics; never reuse cache across accounts or stale performance windows. Reject traversal/symlinks and conflicting retries.
4. Provide CLI `validate --input FILE` and `run --input FILE --decisions FILE --dry-run`; offline supplied decisions exercise the full path without credentials. Define a narrow adapter interface for the existing authorized runtime and later optional Jev adapter, not a new agent launcher or model-provider fallback policy.
5. Add a shared human-readable contract with exact downstream import/CLI examples, economic metrics and privacy limits. Generated reports are non-mutating recommendations; model output cannot grant authority or construct executable commands/URLs.

### Hazards and Compatibility

- **Concurrency/atomicity:** design atomic scope-isolated cache/report writes; test concurrent conflicting requests.
- **Migration/rollback:** additive opt-in files only; rollback must preserve original evidence and existing stores.
- **Mixed-version/backward compatibility:** unknown schema versions fail closed; existing Jev/runtime/reporting behavior stays unchanged.
- **Idempotency/retry:** same digest replays safely, conflicting same identity fails; no cross-account reuse.
- **Partial failure/recovery:** budgets/cancellation/security stops save remaining criteria and checkpoint; no default network or automatic fallback escalation.

### Verification Before Dispatch

Worker runs `python3 .agents/scripts/marketing-decision-helper.py validate --input .agents/scripts/tests/fixtures/marketing-decisions/core-valid.json` and the offline `run` path with a supplied fixture. Add/run `python3 .agents/scripts/tests/test-marketing-decisions.py` for schema rejection, cross-account cache isolation, replay/conflicts, unknowns, budget/cancellation and no-network defaults. Run existing `python3 .agents/scripts/tests/test-jev-pilot.py` if shared behavior is reused, plus `.agents/scripts/linters-local.sh --changed`. These future checks are NOT run at briefing time.

```bash
python3 .agents/scripts/tests/test-marketing-decisions.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI verifies consumer-visible output; focused tests cover schema/cache/recovery and permission-negative paths; lint covers changed source/docs.
- **Recoverability:** checkpoint verified work before broad gates; safety stops keep the leaf open, retain remaining criteria and resume offline after the blocker is understood. No release or broad repository gate is required.

## Acceptance Criteria

- [ ] Two distinct domain-shaped fixture batches produce schema-valid evidence-backed decisions and measured/unknown cost fields via the real CLI.
- [ ] Invalid candidates, stale/cross-account cache, malformed inputs and exceeded budgets cannot yield accepted decisions or side effects.
- [ ] Existing Jev/runtime/performance routes remain unchanged and no credentials or network are required for offline completion.
- [ ] Downstream workers receive a stable documented import contract, recovery behavior and focused tests, not only an architecture essay.
