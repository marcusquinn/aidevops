<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18426: Prepare portable bounded model-effort pilot using existing replay

## What

Prepare a reproducible, no-inference pilot package using the existing historical replay implementation. Supply portable public fixture metadata, a sealed-comparison recipe, explicit aggregate execution limits and a handoff consumable on another approved runner. Do not execute paid/provider inference in this task.

## Why

The user wants evidence rather than anecdotes. Existing replay already has qualification, sealed plans, isolated checks and effective-variant validation; rebuilding it would waste work. It also deliberately disables external plugins, MCPs and subagents, so its findings must be labelled isolated-harness evidence rather than aidevops end-to-end efficiency.

## Origin

Created 2026-09-10, interactive auto-dispatch brief. Parent: t18422. Blocked by t18425 (`blocked-by:t18425`). Baseline: `f610e0abaabec36bc38f014f1f69a6fd44a49e88`.

## Pre-flight

- [x] Memory recall: model effort/replay — no relevant hits.
- [x] Discovery pass: inspected existing replay CLI/candidate validation and workflow; no related open PR or matching open implementation issue found.
- [x] File refs verified: CLI options, corpus init, candidate uniqueness, replay test fixture and enforcement guidance inspected.
- [x] Tier: standard — reuse established mechanics inside unchanged sandbox/billing boundaries.
- [x] Seeded draft PR decision recorded: skipped; qualification and dry-run evidence must be produced by the worker.

## Tier

**Selected tier:** `tier:standard`. Case curation and focused integration need normal judgment, not a new sandbox or provider design. If existing controls cannot enforce the decided contract, expose that blocker; do not weaken them.

## How

### Files to Modify

- `EDIT: .agents/scripts/model-replay-cli-options.mjs` — option patterns at line 14.
- `EDIT: .agents/scripts/model-replay-benchmark.mjs` — existing commandPlan/commandRun adapters.
- `EDIT: .agents/scripts/model-replay-plan.mjs` — optional sealed programme budget contract.
- `EDIT: .agents/scripts/model-replay-experiment.mjs` — enforce budget at the existing experiment boundary.
- `EDIT: .agents/scripts/model-replay-cell.mjs` — account for launched/ambiguous cells.
- `EDIT: .agents/scripts/model-replay-results.mjs` — retain budget/receipt evidence.
- `NEW: .agents/scripts/model-replay-budget.mjs` — optional focused budget helper, following current replay modules.
- `EDIT: .agents/scripts/tests/test-model-replay-benchmark.mjs` — fake-runtime verification.
- `NEW: .agents/reference/model-effort-pilot.md` — public protocol.
- `NEW: .agents/configs/model-effort-pilot.json` — portable public source metadata, not raw experiment logs.

### Files Scope

- `.agents/scripts/model-replay-cli-options.mjs`
- `.agents/scripts/model-replay-benchmark.mjs`
- `.agents/scripts/model-replay-plan.mjs`
- `.agents/scripts/model-replay-experiment.mjs`
- `.agents/scripts/model-replay-cell.mjs`
- `.agents/scripts/model-replay-results.mjs`
- `.agents/scripts/model-replay-budget.mjs`
- `.agents/scripts/brief-tier-test-helper.sh`
- `.agents/scripts/tests/test-model-replay-benchmark.mjs`
- `.agents/scripts/tests/model-replay-benchmark-fixture.mjs`
- `.agents/reference/model-effort-pilot.md`
- `.agents/configs/model-effort-pilot.json`
- `.agents/workflows/optimize-tiers.md`

### Complete Write Surface

- **Callers/readers:** `model-replay-benchmark.mjs` CLI init/add-case/qualify/plan/seal/run/report and `model-replay-experiment.mjs` orchestration.
- **Writers/mutation paths:** `model-replay-plan.mjs`, `model-replay-cell.mjs` and `model-replay-results.mjs` write sealed local-only evidence; public protocol/config contain only portable metadata.
- **Tests/fixtures:** `test-model-replay-benchmark.mjs` and `model-replay-benchmark-fixture.mjs` exercise fake-runtime calls and denied egress.
- **Schemas/config:** `model-effort-pilot.json` plus an optional sealed budget extension; `model-replay-candidates.mjs` unique-model validation stays intact.
- **Generated/deployed mirrors:** `setup.sh` deployment remains unchanged; no provider/account settings or deployed files are edited.
- **Migrations/backfills:** `model-replay-plan.mjs` preserves old plan compatibility; no historic-result rewrite or new database.
- **Cleanup/rollback paths:** `model-replay-experiment.mjs` keeps existing isolated-worktree cleanup; code reversion preserves local evidence and consumed budget receipts.

### Implementation Steps

1. Curate three small reproducible aidevops-only cases (one declared simple, standard and thinking), each tied to an immutable public repository base and hidden deterministic fail-to-pass/pass-to-pass checks. Publish source commit metadata/check recipe; keep raw corpus, gold patches, prompts, catalog paths and run artifacts local-only as required by the existing workflow. Do not depend on inaccessible private session archives.
2. Use the supported smaller corpus shape: `init --profiles aidevops --quick-size 3 --full-size 3`. This is an intentionally narrow pilot, not evidence of broad full-suite representativeness. Reconstruct archives from public Git data on the executing runner; qualification repeats three times. Reconstructed prompts/unknown contamination remain labelled and quarantined, never silently marked exact/fresh.
3. Define candidate arms: current Sol-medium baseline; Astra low; Astra medium; Astra's highest supported and observed effort. Names are requests until verified; Max/XHigh are not interchangeable by assumption. Separate same-model primary-effort manifests because `loadCandidates()` rejects duplicate model identities. Freeze starting state, mode, harness/policy and acceptance checks; balance arm order and record cache differences.
4. Set a sealed programme ceiling of 24 inference cell launches including canaries/retries/confirmations, 180 seconds per cell, 90 minutes programme wall time, concurrency one, no automatic budget renewal. Prefer four canary cells, then twelve primary cells, with remaining capacity reserved for confirmation rather than automatic retries. Unavailable arms consume no fake success and never trigger an unapproved substitute model.
5. Existing per-cell timeout is not an aggregate fuse. Add minimal fail-closed pre-launch accounting/resume checks to the existing plan/run path if needed; malformed/missing required pilot budget must stop before inference. Persist consumed launches and completed cells across resume, so restarting cannot refresh the budget. These are execution bounds, not guaranteed dollar or quota caps.
6. Live execution in t18427 is restricted to existing approved OpenAI ChatGPT OAuth, no API-key billing or other provider/account. Preserve enforced egress/sandbox and exact model/effort evidence. Never use a fixture backend in production, downgrade to trusted-local, bypass contamination/permission gates or change defaults. Provide a precise prerequisite failure receipt when the approved runner lacks a control.
7. Run qualification and sealed dry runs with zero provider calls. Store public hashes and recipe in Git so the next worker can rebuild private artifacts locally; do not pass another runner's absolute paths or secrets. Document replay-versus-production limitations and the t18425 report join contract.

### Hazards and Compatibility

- **Concurrency/atomicity:** Programme-level launch reservation must be atomic across all arm manifests; concurrency is one, existing seals/locks remain authoritative.
- **Migration/rollback:** Old plans retain behavior; pilot-required budgets fail closed on mismatch. Revert code/recipe without erasing consumed evidence.
- **Mixed-version/backward compatibility:** New budget contracts are versioned and optional for legacy plans, mandatory for this pilot.
- **Idempotency/retry:** Interrupted/ambiguous launches count until reconciled; restart cannot refund calls, reset the budget or repeat completed cells.
- **Partial failure/recovery:** Preserve sealed receipts and remaining budget, reset each isolated cell workspace, keep gold/checks hidden and never weaken sandbox or dispatch controls.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-model-replay-benchmark.mjs
bash .agents/scripts/brief-tier-test-helper.sh --help
.agents/scripts/linters-local.sh --changed
```

Extend the existing fake-runtime fixtures to prove zero real provider calls, exhaustion before the next launch, restart without budget reset, ambiguous/incomplete launch handling, candidate uniqueness, unavailable variant rejection and unchanged legacy plans. Run actual `qualify`, `plan`, `seal`, `run --dry-run` with rebuilt local pilot artifacts and record hashes plus fixture outcomes. The implementation must publish exact runnable argument lists with placeholders for private artifact locations.

- **Surface mapping:** The existing replay fixture proves isolation/identity plus new aggregate fuses; help validates the unchanged entry point; qualification/sealed dry-run validates the portable recipe without provider calls; changed-file lint covers code/config/docs.

### Progressive Context Plan

Start with CLI options, candidate uniqueness and existing qualification fixture. Read plan/experiment/cell code only to add the bounded shared reservation. Stop when seal/resume invariants and fake-runtime assertions are clear; do not invent another benchmark engine.

## Acceptance Criteria

- [ ] Another runner can rebuild and qualify the three-case pilot from committed public metadata without private transcripts or hardcoded local paths.
- [ ] Dry runs make zero provider calls; live-mode fixtures enforce cell/time/concurrency bounds across interruption and resume.
- [ ] The protocol labels isolated replay, freshness/contamination and unsupported effort honestly; no provider billing, sandbox or routing defaults are changed.

## Safety-Stop Recovery and Seeded Draft PR

No seed. Persist seal, case receipts, remaining budget and exact unavailable prerequisite. A preparation failure keeps this task open; a failed fake backend is not authority to weaken production controls. Resume the same artifacts after the prerequisite is verified, not a newly allocated experiment with refreshed allowance.
