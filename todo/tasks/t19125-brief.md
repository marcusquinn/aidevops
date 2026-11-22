<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t19125: Reset-aware OAuth pool rotation: prefer the account whose quota resets soonest

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `oauth pool rotation reset window account selection` → 0 hits — no relevant lessons
- [x] Discovery pass: 4 recent commits touch target files (latest acd8244acd GH#38959 seat keys); 0 open PRs touch them (open PR 39097 is model-availability only); 0 open claimed issues
- [x] File refs verified: 6 refs checked, all present at HEAD 556cd02bc9
- [x] Tier: `tier:thinking` — the quota data source is unverified and is a consequential design decision
- [x] Seeded draft PR decision recorded: skipped — data source unresolved; a seed would anchor workers to a guess

## Origin

- **Created:** 2026-11-19
- **Session:** opencode:interactive-2026-11-19
- **Created by:** ai-interactive (requested by maintainer)
- **Conversation context:** Maintainer has two Anthropic OAuth seats in the pool: one weekly window resets in ~2.5 days (90% remaining), the other in ~5 days (100% remaining). Asked whether rotation prefers the seat resetting sooner. It does not. As a stopgap, `marcusquinn@mac.com` was given `priority: 10` via `model-accounts-pool set-priority`.

## What

Rotation over Anthropic OAuth seats with equal priority prefers the seat whose usage window (weekly first) resets soonest, provided that seat still has usable quota. In effect it is earliest-deadline-first, so quota that would expire unused gets spent before quota with more runway. When no reset/usage data is known for a seat, behaviour falls back to today's priority-then-LRU ordering unchanged.

## Why

Weekly quota is use-it-or-lose-it. With LRU rotation, the pool alternates seats evenly. The seat that resets sooner can then reset with quota unused while the later seat is drained. That wastes paid capacity and pushes the pool toward exhaustion earlier in the week. The only lever today is a manual static `priority`, and it goes stale after every reset.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No: the data source and storage field shape are undecided.
- [x] **Targets and reference pattern verified?** All four selection comparators are listed below.
- [ ] **No semantic or design decision remains?** No: the data source, staleness policy and remaining-quota threshold are open.
- [x] **Bounded, reversible, low-consequence impact?** Ordering only; the fallback preserves current behaviour.
- [ ] **No stateful coordination to invent?** New persisted per-seat usage fields need a writer and freshness rules.
- [x] **Focused verification and rollback are explicit?**
- [ ] **No dispatch-path risk override?** OAuth pool selection feeds headless worker auth.

**Selected tier:** `tier:thinking`

**Tier rationale:** The quota/reset data source is not verified in this repo and must be chosen with evidence. The change also touches credential selection used by headless workers.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/plugins/opencode-aidevops/oauth-pool.mjs:91-154` (comparator + `selectPoolAccount`) and `.agents/plugins/opencode-aidevops/claude-proxy-retry.mjs:22-152` (only place a reset time is seen today).
- **Load only if:** `.agents/plugins/opencode-aidevops/provider-auth.mjs:197-231` when changing mid-session 429 rotation; `.agents/scripts/oauth-pool-lib/pool_ops_rotate.py:89-109` when changing CLI rotation.
- **Why:** these are every place that orders seats; they must agree.
- **Stop when:** a verified data source is chosen and every comparator below is routed through one shared ordering rule.

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/oauth-pool.mjs:96-101` — `compareAccountPriority`: within equal priority, order by soonest known reset of a seat that still has quota, then LRU.
- `EDIT: .agents/plugins/opencode-aidevops/provider-auth-pool.mjs:63-68` — `getAvailableAlternates` sorts by LRU only (it ignores priority today). Route it through the shared comparator.
- `EDIT: .agents/plugins/opencode-aidevops/claude-proxy-retry.mjs:35-42` — `sortAccountsByPriority` (priority, then seat key). Use the shared rule. Also persist `rate_limit_info` data (line 146) rather than keeping it only in the in-memory `rateLimitedAccounts` map.
- `EDIT: .agents/scripts/oauth-pool-lib/pool_ops_rotate.py:89-109` — `_select_rotation_candidate`: same ordering for Tier-1 candidates.
- `EDIT: .agents/plugins/opencode-aidevops/oauth-pool-storage.mjs:25-40` — document any new per-seat fields in the account typedef.
- `EDIT: .agents/plugins/opencode-aidevops/oauth-pool-display.mjs` — show known reset time / remaining quota per seat in `model-accounts-pool list`, so ordering is explainable.

### Complete Write Surface

- **Callers/readers:** `selectPoolAccount` (oauth-pool.mjs:140) → `injectPoolToken`, `selectRuntimePoolAccount` (V2 path, v2-provider-auth.mjs:169); `getAvailableAlternates` → provider-auth.mjs:76,216,272; `getAvailableAccounts` (claude-proxy-retry.mjs:78); CLI `oauth-pool-helper.sh rotate` → pool_ops_rotate.py.
- **Writers/mutation paths:** `patchAccount` (oauth-pool-storage.mjs) is the only writer to use for new fields; `handle429Recovery` (provider-auth.mjs:213) already writes `cooldownUntil`.
- **Existing verification/tests:** `.agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs`, `.agents/scripts/oauth-pool-lib/tests/test_pool_ops.py`, `tests/test-oauth-pool-helper.sh`; offline diagnostic `.agents/scripts/oauth-pool-rotation-probe.mjs`.
- **Schemas/config:** pool account entries documented by the typedef in `.agents/plugins/opencode-aidevops/oauth-pool-storage.mjs` (new optional fields; absent = unknown).
- **Generated/deployed mirrors:** deployed copies under `~/.aidevops/agents/` via `setup.sh --non-interactive`; no generated sources.
- **Migrations/backfills:** N/A because the new fields are optional and populate as data arrives; searched `oauth-pool-storage.mjs` and found no schema version to bump.
- **Cleanup/rollback paths:** N/A because reverting the PR is sufficient; evidence: old comparators in `oauth-pool.mjs` read only `priority`/`lastUsed`, so leftover fields are ignored.

### Implementation Steps

1. **Decide the data source with evidence (blocking decision).** Do not guess endpoints or header names. Candidates to verify against live traffic or installed code:
   (a) Anthropic API response headers seen by the provider-auth fetch wrapper (log header names only, never values tied to tokens);
   (b) Claude CLI stream-json `rate_limit_event.rate_limit_info`, which already carries `status` and `resetsAt` (claude-proxy-retry.mjs:144-147). Check whether it also carries window type or utilisation on non-rejected events;
   (c) the usage endpoint the Claude CLI uses for its usage display, only if its URL is found in installed Claude CLI code or official docs.
   Record the chosen source, its rejected alternatives and the evidence in the PR body. If no source gives the reset time before exhaustion, settle for (b) on any rate-limit event. Record the gap.
2. Persist per seat: `usageResetAt` (epoch ms), `usageRemainingPct` (0-100 or null), `usageObservedAt`, written via `patchAccount`. Treat data older than the reset time, or older than a freshness bound you choose and justify, as unknown.
3. Add one shared ordering helper and use it from all four comparators. Rule: explicit `priority` stays primary (a manual pin wins). Within equal priority, seats with a known future reset and remaining quota above a small floor (e.g. 5%) sort ascending by reset time. Seats with unknown data sort after known-good seats, ordered by LRU. Mirror the rule in Python for pool_ops_rotate.py.
4. Show reset/remaining in `model-accounts-pool list` output.
5. Run the existing pool tests and the offline rotation probe; deploy with `setup.sh --non-interactive` and confirm with `model-accounts-pool list`.

### Hazards and Compatibility

- **Concurrency/atomicity:** writes go through `patchAccount`/`withPoolLock`. Do not add a separate write path.
- **Migration/rollback:** optional fields; old code ignores them; rollback = revert.
- **Mixed-version/backward compatibility:** the Python CLI and JS plugin can run different versions. Both must treat missing fields as unknown and fall back to priority+LRU.
- **Idempotency/retry:** repeated observations overwrite with the newer `usageObservedAt` only.
- **Partial failure/recovery:** if usage capture fails, selection behaves exactly as today. Never block auth on usage data.
- **Security:** never log tokens or raw auth headers. Log only seat labels, reset times and percentages.

### Verification Before Dispatch

```bash
node .agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs
python3 -m pytest .agents/scripts/oauth-pool-lib/tests/test_pool_ops.py
bash tests/test-oauth-pool-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** rotation probe covers JS selection; pytest covers `_select_rotation_candidate`; helper test covers CLI rotate; lint covers all changed files.
- **Broad verification trigger:** Not required.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: commands above
- [ ] WIP commit created before broad gates: `wip: reset-aware oauth pool ordering`
- [ ] Evidence-triggered broad verification then run: not required — scoped to pool selection

### Scope Boundaries

**Hard boundaries:** Do not change OpenAI/Google/Cursor selection semantics beyond what the shared comparator implies for missing data (must be identical to today). Do not fetch any URL not verified in step 1.

**AI brief owner:** maintainer interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/plugins/opencode-aidevops/oauth-pool.mjs`
- `.agents/plugins/opencode-aidevops/provider-auth-pool.mjs`
- `.agents/plugins/opencode-aidevops/claude-proxy-retry.mjs`
- `.agents/plugins/opencode-aidevops/oauth-pool-storage.mjs`
- `.agents/plugins/opencode-aidevops/oauth-pool-display.mjs`
- `.agents/plugins/opencode-aidevops/provider-auth.mjs`
- `.agents/plugins/opencode-aidevops/claude-proxy-streaming.mjs`
- `.agents/scripts/oauth-pool-lib/pool_ops_rotate.py`
- `.agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs`
- `.agents/scripts/oauth-pool-lib/tests/test_pool_ops.py`

## Acceptance Criteria

- [ ] With two equal-priority Anthropic seats where seat A has a known reset sooner than seat B and both have quota above the floor, every selection path (`selectPoolAccount`, `getAvailableAlternates`, proxy `getAvailableAccounts`, CLI rotate) picks seat A.

  ```yaml
  verify:
    method: bash
    run: "node .agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs && python3 -m pytest .agents/scripts/oauth-pool-lib/tests/test_pool_ops.py"
  ```

- [ ] When no seat has usage data, ordering is identical to today (priority desc, then LRU), and an explicit higher `priority` still wins over reset ordering.

  ```yaml
  verify:
    method: bash
    run: "python3 -m pytest .agents/scripts/oauth-pool-lib/tests/test_pool_ops.py"
  ```

- [ ] A seat whose remaining quota is at or below the floor, or whose reset time has passed (stale data), is not preferred on reset grounds.
- [ ] `model-accounts-pool list` shows the known reset time and remaining percentage per Anthropic seat, or `unknown`.
- [ ] The PR body records the chosen data source with evidence and the rejected alternatives; no token or auth header value is logged.

  ```yaml
  verify:
    method: codebase
    pattern: "console\\.error\\([^)]*(access|refresh|token)\\b[^)]*\\$\\{account\\.(access|refresh)"
    path: ".agents/plugins/opencode-aidevops"
    expect: absent
  ```

- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Priority stays primary so manual pins keep working. Reset-awareness applies within a priority tier.
- Follow-up for the maintainer once merged: clear the stopgap with `model-accounts-pool set-priority` email `marcusquinn@mac.com` priority `0`.
- Non-goal: predicting burn rate or the "runs out in N days" forecast. Ordering by reset time with a remaining-quota floor is enough.
- Observed: mid-session 429 rotation (`getAvailableAlternates`) ignores `priority` entirely today; fixing that is in scope through the shared comparator.

## Relevant Files

- `.agents/plugins/opencode-aidevops/oauth-pool.mjs:96` — current comparator
- `.agents/plugins/opencode-aidevops/provider-auth-pool.mjs:63` — LRU-only alternates
- `.agents/plugins/opencode-aidevops/claude-proxy-retry.mjs:35,49,144` — proxy ordering and the existing `resetsAt` signal
- `.agents/plugins/opencode-aidevops/provider-auth.mjs:206` — 429 recovery writes `cooldownUntil`
- `.agents/scripts/oauth-pool-lib/pool_ops_rotate.py:89` — CLI rotation

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** live Anthropic OAuth seats to observe the usage data source

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | verify data source; read 4 comparators |
| Implementation | 2h | shared helper JS + Python mirror, persistence, display |
| Verification | 30m | existing pool tests, rotation probe, lint |
| **Total** | **~3h15m** | |
