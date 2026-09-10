<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18425: Report matched objective cost and routing evidence coverage

## What

Extend the existing `report-token-use-helper.sh efficiency` output with source-qualified objective outcomes and matched-cohort economics. Preserve today's request-level report and make incomplete evidence prominent rather than producing an unsupported cheapest-model ranking.

## Why

The current report already separates tokens, effort, cache, pricing and inferred session families. Its explicit null completion metrics at `.agents/scripts/report_token_efficiency.py:170` are correct until the preceding tasks provide attribution. The reviewed Astra Max sample was only five contributing sessions with twice Medium's median context: request-average comparisons are confounded.

## Origin

Created 2026-09-10, interactive auto-dispatch brief. Parent: t18422. Blocked by t18424 (`blocked-by:t18424`), transitively t18423. Baseline: `f610e0abaabec36bc38f014f1f69a6fd44a49e88`; re-read the merged producer contracts.

## Pre-flight

- [x] Memory recall: routing outcome/efficiency — no relevant hits.
- [x] Discovery pass: merged PR #31228 supplies the existing scorecard; no related open PR or duplicate open implementation issue found.
- [x] File refs verified: scorecard collector/lineage, routing feedback reader, command/reference and existing Python/JS tests inspected.
- [x] Tier: standard — cohort/denominator rules and compatibility are specified below.
- [x] Seeded draft PR decision recorded: skipped until producer schemas land.

## Tier

**Selected tier:** `tier:standard`. Established read-only reporting integration, not a new routing algorithm or semantic judge.

## How

### Files to Modify

- `EDIT: .agents/scripts/report_token_efficiency.py` — read-only collection at line 104 and aggregation at line 146.
- `NEW: .agents/scripts/report_token_objectives.py` — optional pure join/aggregation split module.
- `EDIT: .agents/scripts/report-token-use-helper.sh` — additive report options only if needed.
- `EDIT: .agents/scripts/routing-feedback-cli.mjs` — consume source-qualified joins around line 103.
- `EDIT: .agents/scripts/routing-feedback-summary.mjs` — preserve common outcome semantics.
- `EDIT: .agents/scripts/tests/test_report_token_efficiency.py` — exact fixture arithmetic and privacy.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs` — feedback regression checks.
- `EDIT: .agents/scripts/commands/report-token-use.md` — command usage.
- `EDIT: .agents/reference/context-efficiency.md` — report interpretation.

### Files Scope

- `.agents/scripts/report_token_efficiency.py`
- `.agents/scripts/report_token_objectives.py`
- `.agents/scripts/report-token-use-helper.sh`
- `.agents/scripts/routing-feedback.mjs`
- `.agents/scripts/routing-feedback-cli.mjs`
- `.agents/scripts/routing-feedback-summary.mjs`
- `.agents/scripts/tests/test_report_token_efficiency.py`
- `.agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs`
- `.agents/scripts/commands/report-token-use.md`
- `.agents/reference/context-efficiency.md`

### Complete Write Surface

- **Callers/readers:** `report-token-use-helper.sh` invokes `report_token_efficiency.py`; routing feedback consumes the same source-qualified evidence.
- **Writers/mutation paths:** `report_token_efficiency.py` emits stdout/JSON only; no production database initialisation or mutation.
- **Tests/fixtures:** `test_report_token_efficiency.py` and `test-routing-feedback.mjs` cover arithmetic, old schemas and outcome semantics.
- **Schemas/config:** `report_token_efficiency.py` preserves old JSON keys and adds a versioned objective section; existing pricing is read-only.
- **Generated/deployed mirrors:** `setup.sh` deployment remains unchanged; no user/provider config or deployed file edits.
- **Migrations/backfills:** N/A because this task only consumes predecessor fields and existing evidence through read-only queries.
- **Cleanup/rollback paths:** Revert `report_token_efficiency.py`/feedback code to restore prior output; there is no report-owned state to delete.

### Implementation Steps

1. Add source-qualified joins for all descendant sessions and attempts, including ancestors outside the time window. Honour objective boundaries from t18424; deduplicate by request/contribution identity. Report unresolved/shared work separately, never allocate it twice or guess which objective owns it.
2. Freeze observation boundaries. Separate closed matched cohorts from still-running/cancelled/unknown objectives and disclose censoring. For a cohort, primary metric is total attributable expenditure across all included attempts (including failed objectives) divided by verified objectives; zero verified outcomes yields null, not zero cost. Also show acceptance/verification counts and sources.
3. Segment by declared workload class, model, requested/resolved/observed effort, runtime/adapter and policy fingerprint, plus context/cache bands. Unknown/mixed groups remain separate; changed fingerprints or unmatched tasks cannot form an automatic causal comparison. Show independent objective and session counts, not just requests.
4. Include parent/child/repair token and estimated-cost components, observed interventions, active inference time versus wall/CI/tool wait where available, and p50/p95 only with sample counts. Do not sum overlapping durations into wall time. Distinguish normal tool turns, route changes and actual retries; default fields are not evidence of absent transport retries.
5. Keep recorded pricing versions unchanged; reprice only as a labelled comparable estimate with exact model-match coverage and known rate/service-context limitations. Unknown prices, long-context uplifts and shared-account quota attribution stay unavailable, not fabricated dollars or percentages.
6. Add coverage fields for objective mapping, verification, effort evidence, population, lineage and price provenance. Reuse them in feedback without changing automatic routing or downgrading task tiers. Keep public output to aggregates and opaque fingerprints.
7. **Lease attempts to solve:** report the number of distinct won worker leases through verified resolution per issue/solve episode, using t18424's identity/completeness contract. Include median/p95/max, a 1/2/3/4+ distribution and the one-lease share among fully observed solved issues, always with the denominator and independent issue count. Show overall completion rate plus attempts-to-date for unsolved/censored issues alongside these solved-only statistics to avoid survivorship bias.
8. Separate allocated leases, actually launched workers, prelaunch failures, expiry/handoff and evidence-backed no-progress/repair. Renewals, duplicate observations, losing claim races and within-lease model/tool retries must not inflate the lease count. Keep partial historical counts labelled lower-bound/unknown, separate reopened solve episodes from lifetime totals, and preserve per-attempt model/effort attribution for mixed-route issues.
9. Pair lease counts with total issue cost/time including unsuccessful attempts. When showing a cohort ratio of total leases divided by verified solved issues, include failed-issue leases in the numerator, label that cohort ratio separately from per-solved-issue counts, and return null for a zero or unknown verified denominator. Lease counts indicate recovery overhead, not task difficulty or model causality on their own.

### Hazards and Compatibility

- **Concurrency/atomicity:** Use a consistent read-only SQLite snapshot; do not aggregate changing windows into one denominator.
- **Migration/rollback:** No migrations or data rollback; code revert restores the previous reporting view.
- **Mixed-version/backward compatibility:** Missing tables/columns and legacy/mixed prices yield explicit coverage gaps while retaining old request-level output.
- **Idempotency/retry:** Deduplicate events/requests and handle cycles/resumed sessions; rerunning a report cannot mutate evidence.
- **Partial failure/recovery:** Bound queries and report partial/error state rather than empty success. Exclude raw identifiers, paths, transcripts and account data from output.

### Verification Before Dispatch

```bash
python3 .agents/scripts/tests/test_report_token_efficiency.py
node .agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs
.agents/scripts/report-token-use-helper.sh efficiency --since 7d --json
.agents/scripts/linters-local.sh --changed
```

Use disposable fixtures for 2 successful objectives plus 1 failure, descendant/repair joins, multi-objective sessions, shared work, unknown effort/price, no verified outcomes and incomplete windows. Assert hand-calculated totals and denominator, no double counting, original DB bytes unchanged, and no inference/provider calls. The live read-only command is a smoke check, not evidence of a model winner.

Lease arithmetic fixture: solved issue A has one lease plus three renewals; solved B has three distinct leases; unsolved C has two leases. Report solved distribution `{1:1, 3:1}`, median two, one-lease share 1/2, C attempts-to-date two, and the separately labelled cohort ratio six leases / two verified solves = three. Unknown/incomplete history cannot silently enter the complete-history denominator.

- **Surface mapping:** Python fixtures prove attribution/arithmetic/read-only privacy; JS feedback tests prove consistent acceptance semantics; the existing CLI smoke checks production compatibility; changed-file lint covers the edited surface.

### Progressive Context Plan

Read predecessor field contracts and the collector/lineage functions first. Load feedback aggregation only when connecting the same evidence; keep large raw session data outside model context. Stop once each output field has a source, denominator and fixture.

### Complexity Impact

Keep any shell entry-point change to argument forwarding; put new aggregation in the optional Python split module. Do not grow an existing shell function beyond 80 lines; extract a small forwarding helper first if necessary. No shell algorithm or broad refactor is required.

## Acceptance Criteria

- [ ] Fixture totals include failed attempts and all observed parent/child/repair work exactly once, with an independently checkable verified denominator.
- [ ] Unknown/mixed/partial evidence prevents a spurious cheapest-route claim; legacy databases still return useful request-level output.
- [ ] Production smoke output contains no raw private identifiers and leaves historical records/costs untouched.
- [ ] Lease-attempt statistics match the explicit fixture arithmetic, preserve unsolved-issue visibility and do not count renewals as fresh attempts or confuse solved-only statistics with cohort-wide expenditure.

## Recovery and Seeded Draft PR

No seed. Checkpoint after fixture arithmetic and the existing CLI pass. If attribution or a query budget is incomplete, expose the gap and resume a bounded query; do not relabel missing outcomes as failures/successes or increase provider spend.
