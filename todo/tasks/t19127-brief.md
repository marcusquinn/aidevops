<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t19127: Capture Anthropic usage-window data on the built-in anthropic provider path for reset-aware rotation

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `oauth pool rotation reset window account selection` → 0 hits — no relevant lessons
- [x] Discovery pass: PR 39143 (t19125, merged 2026-11-19) added reset-aware ordering; 0 open PRs touch `provider-auth.mjs` or `v2-provider-auth.mjs`
- [x] File refs verified: 5 refs checked, all present at HEAD 83390d35d1
- [x] Tier: `tier:thinking` — the response-header names are unverified and the change touches credential selection for headless workers
- [x] Seeded draft PR decision recorded: skipped — header names must be confirmed against live traffic first

## Origin

- **Created:** 2026-11-19
- **Session:** opencode:interactive-2026-11-19
- **Created by:** ai-interactive (requested by maintainer)
- **Parent task:** follow-up from t19125 (GH#39137, PR 39143, merged)
- **Conversation context:** After PR 39143 merged, the maintainer asked to clear the stopgap `priority: 10` on `marcusquinn@mac.com`. Review showed the new usage capture runs only on the `claudecli` proxy (`recordAccountUsage` in `claude-proxy-streaming.mjs`). Sessions on the built-in `anthropic` provider never populate `usageResetAt`, so ordering silently falls back to LRU there. The priority pin stays until this lands.

## What

Requests made through the built-in `anthropic` provider (V1 `createProviderAuthHook` fetch and the V2 response hook) record the seat's usage window (`usageResetAt`, `usageRemainingPct`, `usageWindow`, `usageObservedAt`) via the existing `shouldReplaceUsage` + `patchAccount` path. `model-accounts-pool list` then shows real reset data for seats used by normal OpenCode Anthropic sessions, and `compareByReset` orders them earliest-deadline-first.

## Why

t19125's ordering only gets data from the Claude CLI proxy (`claudecli` provider, started lazily in `index.mjs:602-606`). The default interactive and headless path is `anthropic/*` through `provider-auth.mjs`, which never calls `recordAccountUsage`. So the feature is inert for the main path, and manual priority pins are still needed.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No: header names and value formats are unverified.
- [x] **Targets and reference pattern verified?** Capture points and the reference pattern (`recordAccountUsage`) are below.
- [ ] **No semantic or design decision remains?** Mapping headers to window/utilisation semantics is open.
- [x] **Bounded, reversible, low-consequence impact?** Best-effort capture; ordering already falls back safely.
- [x] **No stateful coordination to invent?** Reuses `shouldReplaceUsage`/`patchAccount`.
- [x] **Focused verification and rollback are explicit?**
- [ ] **No dispatch-path risk override?** Provider auth feeds headless worker requests.

**Selected tier:** `tier:thinking`

**Tier rationale:** The Anthropic response-header contract must be confirmed from live traffic before mapping it. The code also sits on the auth path that every Anthropic request uses.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/plugins/opencode-aidevops/oauth-pool-ordering.mjs` (full, 115 lines: `usagePatchFromRateLimitInfo`, `shouldReplaceUsage`, `compareByReset`) and `.agents/plugins/opencode-aidevops/claude-proxy-retry.mjs` `recordAccountUsage` (reference pattern).
- **Load only if:** `.agents/plugins/opencode-aidevops/v2-provider-auth.mjs:90-155` when wiring the OpenCode V2 path.
- **Why:** the new capture must produce the same patch shape and replacement rules as the proxy path.
- **Stop when:** header names are verified from one live response and both provider paths call one shared capture helper.

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/oauth-pool-ordering.mjs` — add `usagePatchFromResponseHeaders(headers, now)` that returns the same patch shape as `usagePatchFromRateLimitInfo`, or null.
- `EDIT: .agents/plugins/opencode-aidevops/provider-auth.mjs:320-332` — after the final `response` is known in `executeAuthenticatedFetch`, record usage for `currentKey` (best-effort, never throws, before `transformResponseStream`).
- `EDIT: .agents/plugins/opencode-aidevops/v2-provider-auth.mjs:130-155` — same capture for `provider === "anthropic"` in the V2 response hook.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs` — extend the existing probe cases only if needed to cover the header mapping.

### Complete Write Surface

- **Callers/readers:** `compareByReset` consumers already wired by PR 39143: `oauth-pool.mjs` `selectPoolAccount`, `provider-auth-pool.mjs` `getAvailableAlternates`, `claude-proxy-retry.mjs` `sortAccountsByPriority`, `oauth-pool-lib/pool_ops_rotate.py`; display via `oauth-pool-display.mjs` `describeUsage`.
- **Writers/mutation paths:** `patchAccount` in `oauth-pool-storage.mjs` only, gated by `shouldReplaceUsage`.
- **Existing verification/tests:** `.agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs`, `.agents/scripts/oauth-pool-lib/tests/test_pool_ops.py`, live `model-accounts-pool list`.
- **Schemas/config:** reuses the fields documented in `oauth-pool-storage.mjs` by PR 39143; no new fields.
- **Generated/deployed mirrors:** deployed copies under `~/.aidevops/agents/plugins/opencode-aidevops/` via `setup.sh --non-interactive`.
- **Migrations/backfills:** N/A because the fields already exist and populate on the next request; searched `oauth-pool-storage.mjs` and found no schema version.
- **Cleanup/rollback paths:** N/A because reverting removes capture only; evidence: `usableResetAt` in `oauth-pool-ordering.mjs` treats stale data as unknown after reset or 8 days.

### Implementation Steps

1. **Verify header names (blocking).** Temporarily log only the *names* of response headers whose names contain `ratelimit` from one live `anthropic` OAuth response, plus their values for those headers only (never `authorization`, cookies or tokens). Record the observed names, value formats (epoch seconds vs ISO, fraction vs percent) and which window each covers in the PR body. Remove the temporary log before committing. If no reset/utilisation headers exist on successful responses, record that. Then capture only on 429 responses that carry a reset value, and note the gap.
2. Implement `usagePatchFromResponseHeaders` beside `usagePatchFromRateLimitInfo`, reusing `toMs` and the same remaining-percent clamping. Prefer the weekly window when several are present (match `WINDOW_RANK`).
3. Add a best-effort `recordSeatUsageFromResponse(seatKey, response)` (model on `recordAccountUsage`: try/catch, `shouldReplaceUsage`, `patchAccount`). Call it from both provider paths. Skip if `seatKey` is null.
4. Deploy with `setup.sh --non-interactive`, make one Anthropic request, and confirm `model-accounts-pool list` shows `resets in …` for the active seat.

### Hazards and Compatibility

- **Concurrency/atomicity:** `patchAccount` uses the pool lock; a write per response is acceptable, but skip the write when `shouldReplaceUsage` returns false to avoid lock churn.
- **Migration/rollback:** no schema change; revert removes capture only.
- **Mixed-version/backward compatibility:** older Python CLI ignores or already understands the fields from PR 39143.
- **Idempotency/retry:** replacement is newest-observation-wins within a window rank; repeated responses are harmless.
- **Partial failure/recovery:** any parse error leaves the response untouched; never consume or clone the body for this.
- **Security:** never log token-bearing headers; the permanent code logs nothing beyond seat label and reset time.

### Verification Before Dispatch

```bash
node .agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs
python3 -m unittest discover -s .agents/scripts/oauth-pool-lib/tests
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** probe covers ordering and the header mapping; unittest guards the Python mirror against regressions; lint covers changed JS; the live `model-accounts-pool list` check proves capture on the real provider path.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not read or clone response bodies; do not log auth headers; do not change OpenAI/Google/Cursor paths.

**AI brief owner:** maintainer interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/plugins/opencode-aidevops/oauth-pool-ordering.mjs`
- `.agents/plugins/opencode-aidevops/provider-auth.mjs`
- `.agents/plugins/opencode-aidevops/v2-provider-auth.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs`

## Acceptance Criteria

- [ ] After one request through the built-in `anthropic` provider, `model-accounts-pool list` shows a non-`unknown` reset for the seat that served it.

  ```yaml
  verify:
    method: manual
    prompt: "Deploy, make one anthropic/* request, run model-accounts-pool list; the active seat shows 'resets in'."
  ```

- [ ] `usagePatchFromResponseHeaders` maps the verified headers to the same patch shape as `usagePatchFromRateLimitInfo`, and returns null when the headers are absent.

  ```yaml
  verify:
    method: bash
    run: "node .agents/plugins/opencode-aidevops/tests/test-oauth-pool-rotation-probe.mjs"
  ```

- [ ] Regression: no auth/token header is logged, and requests without ratelimit headers behave exactly as before (no pool write).

  ```yaml
  verify:
    method: codebase
    pattern: "console\\.error\\([^)]*(authorization|x-api-key)"
    path: ".agents/plugins/opencode-aidevops"
    expect: absent
  ```

- [ ] The PR body records the observed header names and formats as evidence.
- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Header-based capture was rejected in t19125 only because the names were unverified in the repo. This task verifies them from live traffic instead of guessing.
- Once merged and deployed, the maintainer clears the stopgap: `model-accounts-pool set-priority` email `marcusquinn@mac.com` priority `0`.

## Relevant Files

- `.agents/plugins/opencode-aidevops/provider-auth.mjs:303` — `executeAuthenticatedFetch`, V1 capture point
- `.agents/plugins/opencode-aidevops/v2-provider-auth.mjs:151` — V2 anthropic response handling
- `.agents/plugins/opencode-aidevops/oauth-pool-ordering.mjs` — shared patch/ordering helpers
- `.agents/plugins/opencode-aidevops/claude-proxy-retry.mjs` — `recordAccountUsage` reference pattern

## Dependencies

- **Blocked by:** none (t19125 merged)
- **Blocks:** removing manual priority pins for reset-aware ordering
- **External:** one live Anthropic OAuth seat for header verification

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | ordering module, provider paths, live header check |
| Implementation | 1h | mapper + capture in V1/V2 |
| Verification | 30m | probe, unittest, live list |
| **Total** | **2h** | |
