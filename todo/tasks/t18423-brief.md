<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18423: Record model-effort harness and cost provenance

## What

Extend request telemetry with unambiguous execution/estimate provenance while preserving the existing routing and token ledger. Users must be able to distinguish requested effort, runtime-resolved effort, observed message effort and genuinely provider-confirmed effort without treating configuration as confirmation.

## Why

The reviewed seven-day snapshot has 37,583 requests across 50 framework versions. Effort labels exist for 99.24%, but `.agents/plugins/opencode-aidevops/observability.mjs:399` uses `msg.variant || routing.variant`; the source is lost. Cost calculation can use fallback prices without a per-row quality marker. Existing scorecard work from merged PR #31228 is the foundation, not work to duplicate.

## Origin

Created 2026-09-10 by interactive OpenCode planning, explicitly authorised for auto-dispatch. Parent: t18422. No blocker beyond canonical publication. Baseline: `f610e0abaabec36bc38f014f1f69a6fd44a49e88`.

## Pre-flight

- [x] Memory recall: effort/telemetry/objective optimisation — no relevant hits.
- [x] Discovery pass: zero target commits in the last 48h at the baseline; merged PR #31228 already supplies efficiency reporting; no related open PR or matching implementation issue found.
- [x] File refs verified: schema, writer, effort handlers, callback, pricing and named tests inspected at baseline.
- [x] Tier: standard — additive recording within decided semantics; no routing/permission decision changes.
- [x] Seeded draft PR decision recorded: skipped; schema changes require the implementation's own verification.

## Tier

**Selected tier:** `tier:standard`. Normal integration/migration judgment remains, so not simple. No dispatch-path mutation is included.

## How

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/observability-init.mjs` — schema and readiness predicate at line 66.
- `EDIT: .agents/plugins/opencode-aidevops/observability.mjs` — migration at line 135 and request writer at line 372.
- `EDIT: .agents/plugins/opencode-aidevops/observability-routing.mjs` — queue evidence; callback is already wired at `index.mjs:476`.
- `EDIT: .agents/plugins/opencode-aidevops/subagent-effort-handlers.mjs` — capture requested/resolved evidence around line 169.
- `EDIT: .agents/plugins/opencode-aidevops/observability-pricing.mjs` — expose estimate provenance around line 98.
- `NEW: .agents/plugins/opencode-aidevops/observability-provenance.mjs` — optional focused serializer, following existing observability modules.
- `EDIT: .agents/reference/observability.md` — document the additive evidence contract.

### Files Scope

- `.agents/plugins/opencode-aidevops/observability-init.mjs`
- `.agents/plugins/opencode-aidevops/observability.mjs`
- `.agents/plugins/opencode-aidevops/observability-routing.mjs`
- `.agents/plugins/opencode-aidevops/observability-pricing.mjs`
- `.agents/plugins/opencode-aidevops/observability-provenance.mjs`
- `.agents/plugins/opencode-aidevops/subagent-effort-handlers.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-observability-pricing.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-observability-cost-backfill.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs`
- `.agents/scripts/tests/test-observability-concurrent-init.sh`
- `.agents/reference/observability.md`

### Complete Write Surface

- **Callers/readers:** `index.mjs`, `subagent-effort-handlers.mjs`, `report_token_efficiency.py` and routing feedback consume root/child recording evidence.
- **Writers/mutation paths:** `observability.mjs` request INSERT and `observability-init.mjs` schema setup; session summaries keep numeric compatibility.
- **Tests/fixtures:** `test-observability-routing-join.mjs`, `test-observability-pricing.mjs`, `test-observability-cost-backfill.mjs`, `test-subagent-effort.mjs` and `test-observability-concurrent-init.sh`.
- **Schemas/config:** `observability-init.mjs` and `_runDataMigrations` add nullable provenance; existing pricing configuration is consumed, not changed.
- **Generated/deployed mirrors:** `setup.sh` deploys source; no deployed copy or user config is directly edited.
- **Migrations/backfills:** `observability.mjs` additive migration and fast-path readiness must agree; no mass or historical backfill.
- **Cleanup/rollback paths:** `observability.mjs` compatibility permits reverting code while retaining additive columns; no destructive DB cleanup.

### Implementation Steps

1. Add nullable fields (or one versioned bounded provenance object with equivalently queryable fields): requested/resolved/observed effort and source; optional provider-confirmed effort; requested versus observed model; runtime name/version; adapter/plugin/framework version; routing-policy and applicable agent/prompt-policy fingerprints; service/billing mode when observable; cost source and pricing-match quality.
2. Capture requested effort before clamping, resolved effort after existing same-model clamping, and observed effort from actual host evidence. Unknown provider-effective effort stays null. Never claim internal compute from the variant label. Preserve explicit user pins and all existing routing outputs.
3. Hash only the relevant loaded policy bytes/config snapshot once per applicable lifetime; do not hash private conversation text, persist raw configuration or perform a full tree scan per request. Missing host version/provider acknowledgement is explicit unknown.
4. Keep `variant`, `cost`, token fields and `pricing_version` backward compatible. New cost provenance distinguishes exact, family/fallback and unknown pricing plus API-equivalent versus provider-observed values. Do not reprice old rows, translate estimates into quota percentages, or double-count reasoning already included in a host's output total; verify installed runtime usage semantics before changing normalisation.
5. Cover both fresh DB and existing schema fast paths. Partial recording failure must not break inference. No new automatic model escalation or always-loaded prompt expansion.

### Hazards and Compatibility

- **Concurrency/atomicity:** Preserve the existing init lock and SQLite busy handling; fast-path readiness must include new columns.
- **Migration/rollback:** Nullable additive migration only; rollback leaves columns unused and never drops/backfills history.
- **Mixed-version/backward compatibility:** Existing fields/readers remain valid; old rows retain unknown provenance.
- **Idempotency/retry:** Repeated startup must converge without duplicate migration or repeated policy hashing per request.
- **Partial failure/recovery:** Recording remains fail-open; unavailable provider/runtime metadata stays unknown. Bound hashes/strings and exclude private data.

### Verification Before Dispatch

Implementation acceptance commands (not yet run for the new feature):

```bash
node .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs
node .agents/plugins/opencode-aidevops/tests/test-observability-pricing.mjs
node .agents/plugins/opencode-aidevops/tests/test-observability-cost-backfill.mjs
node .agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs
bash .agents/scripts/tests/test-observability-concurrent-init.sh
.agents/scripts/linters-local.sh --changed
```

Extend these existing fixtures for requested≠clamped≠observed, absent provider evidence, unknown prices, identical replay/idempotency and mixed old/new DBs. Exercise the real recording hook against a disposable DB and inspect the rows; synthetic tests must not write production history or contact a provider.

- **Surface mapping:** Routing/subagent tests cover pins/clamps and recorded identity; pricing/backfill tests cover estimate provenance and unchanged history; concurrent-init covers migration atomicity; changed-file lint covers the complete edited surface.

### Progressive Context Plan

Read the writer, migration and effort callback first; load pricing and the corresponding fixture only when implementing that field. Stop when the field source and compatibility test are identified; do not reload the full parent transcript or all observability modules.

## Acceptance Criteria

- [ ] Root and child requests expose source-qualified effort/model/harness/price provenance, including a clamp mismatch fixture.
- [ ] Old rows remain byte-for-byte unchanged; unknown provider effort/price quality remains unknown and cannot appear as verified cheap usage.
- [ ] Concurrent startup, existing summaries and user-pinned routing continue to work; no real provider calls or default changes occur.

## Recovery and Seeded Draft PR

No seed. After the focused recording path passes, checkpoint intended changes before broader gates. On a migration/lock failure preserve the original DB and logs, repair on a disposable fixture, and keep acceptance open; never reset production telemetry or bypass hooks.
