<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18125: Measure exact GitHub transport attempts and replayable budgets

Parent: t18124

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `GitHub API transport telemetry retry pagination budget retention` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 2 target-file commits / 0 overlapping open PRs; recent gh-shim recursion work is compatible and must be preserved
- [x] File refs verified: 4 source/test surfaces checked, all present at `313548fc6`
- [x] Tier: `tier:thinking` — transport-boundary placement and backward-compatible telemetry schema require design judgment
- [x] Seeded draft PR decision recorded: skipped — gather a clean baseline after implementation rather than seed unverified instrumentation

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive GitHub API efficiency planning
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18124
- **Blocked by:** None; this is the only initially eligible leaf
- **Conversation context:** Existing `gh_record_call` sites count routed logical operations before or around execution. The programme needs exact network-attempt evidence before later cache phases can claim savings.

## What

Move or augment GitHub API instrumentation at the real gh transport boundary so every network attempt has one durable record and cache-only operations cannot masquerade as requests. Record logical-operation and attempt identities, retry/page metadata, route/auth/pool, status/outcome, elapsed time, and available quota cost. Replace fixed-line retention reporting with honest retained-range metadata and provide fixture replay for API budgets.

## Why

The current TSV at `gh-api-instrument.sh:45-55` records one row whenever a caller invokes `gh_record_call`, which is not proof of an HTTP attempt. Retries, pagination, shim recursion, cache hits, and failed preflight routes can overcount or undercount. The aggregator also reports the requested 24-hour window even when trimming retained less history. Every later optimisation needs an auditable baseline derived from actual transport attempts.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — recorder, aggregator, shim, and tests coordinate.
- [ ] **Every target file under 500 lines?** No — `.agents/scripts/gh` exceeds 500 lines.
- [ ] **Exact oldString/newString for every edit?** No — the worker must choose the narrowest true transport boundary.
- [ ] **No judgment or design decisions?** No — logical operations and attempts require separate identities.
- [ ] **No error handling or fallback logic to design?** No — retries, pagination, failures, and legacy records need explicit behavior.
- [ ] **No cross-package or cross-module changes?** No — shell and awk output contracts change together.
- [ ] **Estimate 1h or less?** No — baseline and fixture work is estimated at two hours active plus observation.
- [ ] **4 or fewer acceptance criteria?** No — accuracy, privacy, retention, compatibility, and replay are independently testable.
- [x] **Dispatch-path classification:** Targets do not match `.agents/configs/self-hosting-files.conf`; normal auto-dispatch is permitted.

**Selected tier:** `tier:thinking`

**Tier rationale:** The task is bounded but architectural: instrumentation must be placed where one record equals one attempted request without double-recording translated REST, native gh, retry, or pagination paths.

## PR Conventions

Leaf task. The implementation PR closes only this issue and references parent t18124 with a non-closing parent reference.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A seed before choosing and testing the true transport boundary could duplicate records or break shim recursion guards.
- **Status:** `not-created`
- **Freshness evidence:** Recorder, aggregator, shim call sites, and focused tests were checked at `313548fc6`.
- **Verification run:** Brief readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-check `.agents/scripts/gh` after any shim or native-binary resolution change.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/gh-api-instrument.sh:45-175,178-251` — current schema, recorder, aggregator contract, and trim behavior.
- **Then read:** `.agents/scripts/gh:202-225,430-470,630-710,1430-1590` — native resolution, route execution, pagination, fallback, and existing record sites.
- **Load only if:** recursion or native executable selection changes — inspect `.agents/scripts/tests/test-gh-shim-recursion.sh` and preserve its generation guard.
- **Why:** One attempted transport must create one record at the execution boundary, while logical routing remains separately observable.
- **Stop when:** fixtures can reconcile known commands, retries, pages, cache-only decisions, and retained windows exactly.

### Worker Quick-Start

```bash
rg -n 'gh_record_call|_GH_REAL_BIN|exec .*gh|--paginate|route_decision' .agents/scripts/gh .agents/scripts/gh-api-instrument.sh
bash .agents/scripts/tests/test-gh-api-instrument.sh
```

### Files to Modify

- `EDIT: .agents/scripts/gh-api-instrument.sh:45-55,98-175,178-251` — add a versioned attempt record, honest effective-window metadata, and bounded time/size retention.
- `EDIT: .agents/scripts/gh-api-aggregate.awk:24-130` — aggregate attempts separately from logical/cache events and report first/last retained timestamps plus effective seconds.
- `EDIT: .agents/scripts/gh:202-225,430-470,630-710,1430-1590` — emit exactly once around each native transport attempt and classify retry/page/cache routing without exposing arguments.
- `EDIT: .agents/scripts/tests/test-gh-api-instrument.sh` — fixture matrix for attempts, retries, pages, legacy TSV, privacy, retention, and effective windows.

### Complete Write Surface

- **Callers/readers:** Existing wrapper functions call `gh_record_call`; report consumers read `gh-api-calls-by-stage.json`. Preserve old call signatures while the shim adds richer attempt fields.
- **Writers/mutation paths:** `gh_record_call`, new transport-attempt helper if extracted, `gh_trim_log`, and shim execution branches write the append-only log or retained replacement.
- **Tests/fixtures:** `test-gh-api-instrument.sh` is the primary fixture; include native, REST translation, forced retry, pagination, cache-only, malformed legacy, and concurrent append cases.
- **Schemas/config:** `.agents/scripts/gh-api-instrument.sh` TSV and `.agents/scripts/gh-api-aggregate.awk` JSON additions require a schema/version field and defaults for seven-column legacy rows; existing environment overrides remain valid.
- **Generated/deployed mirrors:** `.agents/scripts/gh*` deploy through `setup.sh`; do not edit the active runtime-bundle copy.
- **Migrations/backfills:** `.agents/scripts/gh-api-aggregate.awk` performs no destructive backfill; it reads legacy rows as logical events with unknown attempt identity and excludes them from exact-attempt claims unless explicitly marked.
- **Cleanup/rollback paths:** `gh_trim_log` and an optional compatibility flag may disable rich fields while preserving the old recorder; trim writes atomically and keeps the last valid log if replacement fails.

### Implementation Steps

1. Define a backward-compatible record version with `event_kind`, `logical_id`, `attempt_id`, `page`, `retry`, `path`, `auth`, `pool`, `decision`, `outcome`, `http_status`, `elapsed_ms`, `quota_cost`, and caller. Do not record URLs with query values, request bodies, headers, tokens, or command arguments.
2. Keep `gh_record_call` available for logical/cache routing events, but introduce a distinct helper or mode emitted immediately around native gh execution. Generate one logical ID per wrapper invocation and one attempt ID per actual try/page.
3. Ensure REST translators and fallback retries record the chosen transport exactly once; a GraphQL failure followed by REST produces two attempts under one logical ID, while a cache hit produces zero attempts and one cache event.
4. Make the aggregator output logical events, attempted requests, retries, pages, outcomes, elapsed totals, and quota cost separately. Set `effective_window_seconds` from the earliest and latest retained attempt, and retain requested window separately.
5. Replace line-only trimming with bounded time and size behavior that is atomic and portable. Retention must never claim history that has already been discarded.
6. Add deterministic fixture replay that sums expected HTTP attempts and quota cost by caller/path and rejects duplicate attempt IDs.

### Hazards and Compatibility

- **Concurrency/atomicity:** Multiple processes append concurrently. Keep each record below atomic append limits and use atomic replacement for trim; never truncate an actively written log in place.
- **Migration/rollback:** Legacy rows remain readable. Rich writers can be disabled without making old reports unparsable.
- **Mixed-version/backward compatibility:** Old call sites using six optional args continue to work; new aggregation labels their rows as logical/legacy rather than proven transport attempts.
- **Idempotency/retry:** Every retry/page gets a new attempt ID under the same logical ID. Re-running aggregation is read-only and deterministic.
- **Partial failure/recovery:** Instrumentation remains fail-open for host commands, but malformed or missing telemetry is explicit in report metadata and cannot support a savings claim.

### Complexity Impact

- **Target functions:** `gh_record_call` and `gh_trim_log` in `gh-api-instrument.sh`, plus native execution branches in `.agents/scripts/gh`.
- **Current line count:** `gh_record_call` is about 60 lines; the shim contains large route functions.
- **Estimated growth:** More than 100 lines across helpers and tests.
- **Projected post-change:** Existing route functions risk the 100-line gate if instrumentation is inlined.
- **Action required:** Extract small record construction, attempt execution, and retention helpers; do not add repeated branches to the large shim functions.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-gh-api-instrument.sh
shellcheck .agents/scripts/gh-api-instrument.sh .agents/scripts/gh .agents/scripts/tests/test-gh-api-instrument.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The focused fixture proves schema compatibility, exact attempts, replay, privacy, retention, and aggregation; ShellCheck covers Bash 3.2/explicit-return style; changed lint covers awk and repository gates.
- **Broad verification trigger:** Required only if `.agents/scripts/gh` transport execution changes beyond instrumentation placement.
- **Broad verification command:** Use the bounded repository linter plus normal PR CI after the WIP checkpoint.

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-gh-api-instrument.sh`
- [ ] WIP commit created before broad gates: `wip: measure exact GitHub transport attempts`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Establish exact, privacy-safe GitHub transport and quota telemetry before optimisation.
- **Preserved user directions:** Dispatch this phase first and collect a 12–24 hour baseline.
- **Trigger and evidence:** Not triggered at brief creation.
- **Completed and verified:** Current logical recorder, trim behavior, aggregator, and shim sites identified.
- **Remaining acceptance criteria:** All implementation and baseline criteria below.
- **Unsafe route not to repeat:** Do not label logical wrapper invocations as network requests or expose raw command arguments.
- **Next safe route:** Implement fixture-first record semantics, then instrument one transport path at a time.
- **Resume condition:** Focused fixtures pass and shim recursion tests remain green.
- **Owner and status:** Build+ `tier:thinking`; not-triggered.

### Files Scope

- `.agents/scripts/gh-api-instrument.sh`
- `.agents/scripts/gh-api-aggregate.awk`
- `.agents/scripts/gh`
- `.agents/scripts/tests/test-gh-api-instrument.sh`
- `.agents/scripts/tests/test-gh-shim-recursion.sh`

## Acceptance Criteria

- [ ] Fixture replay reports exactly one attempt per real try/page and zero attempts for cache-only results, with retries linked to one logical operation.
- [ ] Reports separate logical events, attempts, retries, pages, outcomes, elapsed time, and known quota cost by caller/path/auth pool.
- [ ] Retention is atomic and bounded, and report metadata states requested versus actual retained/effective windows from observed timestamps.
- [ ] Legacy seven-column records remain readable without being misrepresented as exact transport attempts.
- [ ] Telemetry never contains tokens, authorization headers, request bodies, private command arguments, or unsanitized query values.
- [ ] Instrumentation failures never alter gh command exit codes or output, and shim recursion/native-binary guards remain intact.
- [ ] A 12–24 hour baseline report is attached to or linked from the issue before t18126 is promoted.

## Context & Decisions

- Transport attempts, not wrapper invocations, are the optimisation denominator.
- Cache events remain observable but do not count as requests.
- Exact quota cost is recorded when headers/API metadata provide it; unknown is distinct from zero.
- Legacy data supports continuity but not exact-savings claims.

## Relevant Files

- `.agents/scripts/gh-api-instrument.sh:45-55,98-175,178-251` — current TSV schema, recorder, requested window, and fixed-line trim.
- `.agents/scripts/gh-api-aggregate.awk:24-130` — current count-only aggregation and configured window reporting.
- `.agents/scripts/gh:202-225,430-470,630-710,1430-1590` — native command selection, route execution, fallback, and current logical record sites.
- `.agents/scripts/tests/test-gh-api-instrument.sh` — existing instrumentation regression harness.

## Dependencies

- **Blocked by:** None.
- **Blocks:** t18126.
- **External:** GitHub responses for baseline observation; fixtures require no live API.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/design | 30m | Transport boundary and schema compatibility |
| Implementation | 60m | Recorder, shim, retention, aggregator |
| Testing | 30m | Fixture replay, privacy, lint |
| Observation | 12–24h wall clock | Baseline before next phase |
| **Total** | **2h active** | |
