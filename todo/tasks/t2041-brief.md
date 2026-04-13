<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2041: feat(pulse): budget-aware LLM sweep with state diff cache

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (Marcus approved combined t2040+t2041 execution)
- **Parent task:** none
- **Conversation context:** User asked whether the pulse LLM sweep would scale to repos with thousands of open issues. Today's sweep reads the full state blob every cycle — O(N). User constraints: "must work with a budget and tools for high-level understanding, pick off highest value opportunities, not have a large cost for every pass when most information will be the same pass to pass". Design agreed: reframe the sweep as O(churn), not O(N), via five cost-capping layers.

## What

Rebuild the pulse LLM sweep around a five-layer cost cap so token cost per cycle is roughly constant regardless of total open-issue count. New primitives:

1. **State digest cache (Layer 1)** — per-runner digest of (issue numbers, labels, assignees, `updatedAt`, PR state). End-of-pass writes digest + cached action list. Next pass compares; if identical AND a cheap verification query returns zero external changes, skip the LLM invocation entirely.
2. **Event-driven delta (Layer 2)** — when digest differs, fetch only what changed via `gh issue list --search "updated:>$LAST_PASS_ISO"`. Cost scales with churn, not total N.
3. **Deterministic pre-filter (Layer 3)** — handle obvious cases in shell before LLM sees them: merged-PR closure, NMR exclusion, parent-task skip, well-formed dispatch, blocked-by-assignee skip. LLM only sees genuinely ambiguous events.
4. **Hard token budget with priority rank (Layer 4)** — cap event-content injection at configurable budget (default 3000 tokens, ~50 events), sort by existing priority order, defer overflow to next cycle with logged reasons. Starvation guard: items deferred ≥3 cycles promoted to front.
5. **Summary-first prompting (Layer 5)** — LLM prompt gets a one-page digest first, requests full bodies only for items it can't resolve from summary.

Hygiene Anomalies section (reading t2040's reconciler counters) added to the digest so the LLM has state-health visibility without extra token cost in the common case (zero anomalies = one line of text).

## Why

Today: `pulse-wrapper.sh` pre-fetches all open issues + PRs into a state blob, injects between `--- PRE-FETCHED STATE ---` markers, LLM reads linearly. ~3K tokens/cycle on aidevops (12 issues). At 1 200 issues: ~60K tokens. At 12 000 issues: unusable. Cost grows linearly with backlog even when almost nothing changed.

The actual information content per cycle is O(churn), not O(N). Between two cycles on the same machine, most state is unchanged. A sweep that re-pays full state cost on every pass for the same conclusions is structurally wasteful. Reframing from "state-scan" to "churn-scan" preserves every dispatch/merge decision the pulse makes today while decoupling cost from total backlog size.

Without this: aidevops works, other pulse-enabled repos don't scale, and the framework can't be recommended for anything beyond small personal repos.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify? **No** — 7 files
- [ ] Complete code blocks for every edit? **No** — new scripts are design work
- [ ] No judgment or design decisions? **No** — cache invalidation, budget semantics, starvation guard
- [ ] No error handling or fallback logic to design? **No** — fail-open cache, deferral semantics
- [ ] Estimate 1h or less? **No** — ~4h
- [ ] 4 or fewer acceptance criteria? **No** — 9 below

**Selected tier:** `tier:reasoning`

**Tier rationale:** Novel architecture (no existing pattern in framework for diff-cached LLM prompts), cache invalidation correctness, starvation semantics, cross-runner implications. Reasoning.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/pulse-state-digest.sh` — compute/compare/write state digest per repo, per runner (`$(hostname -s)` in cache path)
- `NEW: .agents/scripts/pulse-event-delta.sh` — event delta fetcher using `updated:>ISO` search
- `EDIT: .agents/scripts/pulse-wrapper.sh` — state-file assembly section (exact location determined at checkpoint zero); replace full-fetch with digest + delta + Hygiene Anomalies injection
- `NEW: .agents/configs/pulse-sweep-budget.json` — per-repo budget config (`token_budget`, `max_events_per_pass`, `deferral_promotion_threshold`)
- `EDIT: .agents/workflows/pulse-sweep.md` — document new contract: summary-first reading, `gh issue view` on demand, hard budget, cache-hit semantics
- `EDIT: .agents/reference/cross-runner-coordination.md` — note per-hostname digest cache (no cross-runner invalidation needed)
- `NEW: .agents/scripts/tests/test-pulse-state-digest.sh`
- `NEW: .agents/scripts/tests/test-pulse-event-delta.sh`
- `NEW: .agents/scripts/tests/test-pulse-sweep-budget-cap.sh`
- `NEW: .agents/scripts/tests/test-pulse-sweep-end-to-end.sh` — the integration test that can only exist with t2040 + t2041 combined

### Implementation Steps

1. **Checkpoint zero: read `pulse-wrapper.sh` state-file assembly section** to find the exact wiring point. Blocked at this step until I know the surface area. Report back to user if it's more entangled than estimated.

2. **`pulse-state-digest.sh`** — three commands:
   - `compute <repo-slug>` — compute digest from current state, output to stdout
   - `read <repo-slug>` — read last-pass cached digest
   - `write <repo-slug> <digest> <action-list-json>` — persist end-of-pass state
   - `verify <repo-slug>` — run the cheap bounded query (`gh issue list --search "updated:>$LAST_PASS_ISO" --limit 5`) to confirm nothing changed since we wrote
   - Cache path: `~/.aidevops/cache/pulse-state-digest.$(hostname -s).${slug//\//__}.json`

3. **`pulse-event-delta.sh`** — returns events since last pass:

    ```bash
    pulse-event-delta.sh fetch <repo-slug> <last-pass-iso> [--limit N]
    # Returns JSON array: [{number, title, labels, assignees, updatedAt, event_type}]
    # event_type ∈ {created, updated, closed}
    ```

    Queries `gh issue list --search "updated:>ISO"` + `gh issue list --search "created:>ISO"` + diff vs cached issue number set.

4. **Wire into `pulse-wrapper.sh`** state-file assembly (exact insertion point TBD at checkpoint zero). Logic:

    ```bash
    if pulse-state-digest.sh unchanged <slug> && pulse-state-digest.sh verify <slug>; then
        echo "[pulse] state digest unchanged for $slug — skipping LLM sweep (Layer 1 hit)"
        # Replay cached action list against current capacity
        continue
    fi
    events=$(pulse-event-delta.sh fetch "$slug" "$LAST_PASS_ISO")
    # Layer 3 deterministic filters
    events=$(pulse-prefilter.sh "$events")
    # Layer 4 budget cap
    events=$(pulse-budget-cap.sh "$events" --budget 3000 --promote-starved 3)
    # Inject into state file with Hygiene Anomalies from t2040 counters
    ```

5. **Budget config `.agents/configs/pulse-sweep-budget.json`**:

    ```json
    {
      "default": {
        "token_budget": 3000,
        "max_events_per_pass": 50,
        "deferral_promotion_threshold": 3,
        "verification_query_limit": 5
      },
      "per_repo": {}
    }
    ```

6. **Update `workflows/pulse-sweep.md`** §"Read pre-fetched state" — new contract: "The state file contains a one-page digest and a filtered event list. Fetch full issue bodies only via `gh issue view` when the summary is insufficient."

7. **Tests:**
   - `test-pulse-state-digest.sh` — compute / read / write / verify round-trip, hostname isolation
   - `test-pulse-event-delta.sh` — synthetic fixture with 1000 issues, 5 changed → returns 5 rows
   - `test-pulse-sweep-budget-cap.sh` — 100 events + budget 3000 → drops to ~50, promotes starved items
   - `test-pulse-sweep-end-to-end.sh` — pollute state, run pulse cycle, verify t2040 cleans it AND t2041 reports zero anomalies on next cycle AND Layer 1 cache hit fires on third cycle

### Verification

```bash
shellcheck .agents/scripts/pulse-state-digest.sh .agents/scripts/pulse-event-delta.sh

.agents/scripts/tests/test-pulse-state-digest.sh
.agents/scripts/tests/test-pulse-event-delta.sh
.agents/scripts/tests/test-pulse-sweep-budget-cap.sh
.agents/scripts/tests/test-pulse-sweep-end-to-end.sh

# Regression
.agents/scripts/tests/test-pulse-wrapper-characterization.sh

# Live: two consecutive dry-run pulses with no intervening changes
PULSE_DRY_RUN=1 PULSE_FORCE_LLM=1 .agents/scripts/pulse-wrapper.sh 2>&1 | tee /tmp/pulse-1.log
PULSE_DRY_RUN=1 PULSE_FORCE_LLM=1 .agents/scripts/pulse-wrapper.sh 2>&1 | tee /tmp/pulse-2.log
grep "digest unchanged\|Layer 1 hit" /tmp/pulse-2.log  # must find cache hit
```

## Acceptance Criteria

- [ ] `pulse-state-digest.sh` exists with `compute`/`read`/`write`/`verify` subcommands and per-hostname cache path
- [ ] `pulse-event-delta.sh` exists and returns events from `updated:>ISO` search
- [ ] `pulse-wrapper.sh` state-file assembly uses digest + delta path; full fetch only on Layer 1 miss
- [ ] Layer 1 cache hit skips LLM invocation entirely and logs `digest unchanged`
- [ ] Layer 4 hard budget cap enforced; overflow deferred with reasons logged
- [ ] Layer 4 starvation guard: items deferred ≥3 cycles promoted to front of next pass
- [ ] `workflows/pulse-sweep.md` documents the new read contract (summary first, `gh issue view` on demand)
- [ ] `test-pulse-state-digest.sh`, `test-pulse-event-delta.sh`, `test-pulse-sweep-budget-cap.sh`, `test-pulse-sweep-end-to-end.sh` pass
- [ ] `test-pulse-wrapper-characterization.sh` regression suite passes (existing dispatch decisions unchanged)

## Context & Decisions

- **Per-hostname cache, no cross-runner invalidation:** eventual consistency is fine — each runner's cache is independent, the cheap verification query catches drift within one cycle.
- **Fail-open cache:** any error in digest compute / cache read → fall through to full Layer 2 fetch. Never block the pulse on a cache error.
- **Why deterministic pre-filter before LLM:** most events in steady state are well-formed dispatches the shell can handle. Sending them to the LLM wastes tokens on decisions the dispatcher could make on its own.
- **Why `gh issue view` on demand vs full fetch:** the LLM sees summaries cheaply and pulls full bodies only when judgment requires it. Caps the LLM's autonomy over its own token budget.
- **Starvation guard triggers at deferral count ≥3:** arbitrary threshold, chosen because 3 cycles = 3 minutes typical = long enough to accept legitimate ordering but short enough to guarantee progress.
- **Integration test scope:** the end-to-end test is the thesis — t2040's reconciler counters feed t2041's Hygiene Anomalies section feeds Layer 1 cache invalidation. Can only exist with both tasks merged together.

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh` — state-file assembly (location TBD at checkpoint zero)
- `.agents/workflows/pulse-sweep.md` — current sweep contract
- `.agents/scripts/pulse-repo-meta.sh:142` — `list_dispatchable_issue_candidates_json` (existing candidate filter, pattern to follow for deterministic pre-filter)
- `.agents/scripts/pulse-dispatch-core.sh:172` — `check_dispatch_dedup` 7-layer gate (model for Layer 3)
- `.agents/scripts/pulse-issue-reconcile.sh` — t2040's reconciler (source of Hygiene Anomalies counters)
- `.agents/reference/cross-runner-coordination.md` — per-runner state doc

## Dependencies

- **Blocked by:** t2040 (Hygiene Anomalies section reads reconciler counters)
- **Blocks:** future multi-thousand-issue pulse deployments
- **External:** `gh` CLI supports `--search "updated:>ISO"` (verified, existing feature)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Checkpoint zero: read pulse-wrapper.sh | 20m | find state assembly, go/no-go |
| `pulse-state-digest.sh` | 45m | 4 subcommands + cache layout |
| `pulse-event-delta.sh` | 30m | two queries + diff |
| `pulse-wrapper.sh` wiring | 45m | replace full-fetch block |
| Config + docs | 30m | JSON schema + workflow doc update |
| Tests | 90m | 4 test files, stubbed gh fixtures, E2E |
| Verification | 20m | shellcheck, regression, live |
| **Total** | **~4h** | |
