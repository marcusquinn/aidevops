# t18961: GH#37649 follow-up: fail over subagents stuck in provider rate-limit retry

<!-- aidevops:brief-schema=v2 -->

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `subagent rate limit failover retry hook OpenCode V2` → 0 hits — no relevant lessons
- [x] Discovery pass: 5 commits / 4 merged PRs / 0 open PRs touch target files recently (latest: #37654, #37007, #36807)
- [x] File refs verified: 7 refs checked, all present at HEAD `789c381658`
- [x] Tier: `tier:thinking` — the recovery design depends on a host capability that does not exist yet
- [x] Seeded draft PR decision recorded: skipped — Phase 0 may finish without code

## Origin

- **Created:** 2026-11-10
- **Created by:** ai-interactive (maintainer-requested follow-up)
- **Blocked by:** external host capability (see Dependencies)
- **Conversation context:** Follow-up to #37649 / PR #37654. That PR only stops routing new subagents to a provider whose OAuth pool is fully rate-limited. Recovering a child that is already stuck was left out because OpenCode v1.19.5 has no hook that can do it safely. Evidence: https://github.com/marcusquinn/aidevops/issues/37649#issuecomment-6779337431
- **Brief provenance:** Restored from issue #37667 so issue-sync retains the original implementation and acceptance details.

## What

When a running Task subagent is stuck in the host's provider retry loop because its provider's OAuth pool is exhausted, move the work to the next routable same-tier model. The parent must get a normal Task result, not a bare `Task cancelled` and not a wait until the provider resets.

## Why

PR #37654 protects only new children. A child that started before the pool ran out still waits through OpenCode's own retry backoff, which can take hours. Meanwhile the parent session stalls.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Which host hook to use, and how to resume or replay the child without losing work or duplicating side effects, is not decided. It depends on Phase 0 evidence.

## How (Approach)

### Phase 0 — host capability gate (mandatory, first)

Check the installed OpenCode (`opencode --version`, plus the installed package source) for at least one of:

1. a V2 `retry` hook decision that can change the model or provider for the next attempt. Today `.agents/plugins/opencode-aidevops/v2-provider-auth.mjs:152-161` can only set `{ retry, delay }`.
2. a hook that runs when a Task tool call fails or is cancelled and can replace its result. Today `tool.execute.after` does not run on failure or cancel: see `.agents/plugins/opencode-aidevops/subagent-interrupted-task-receipts.mjs:28`, and the V2 adapter applies hook output only when `status === "completed"`.
3. a supported API that can stop a child session and re-run its prompt on another model, so the parent receives the new run's result.

**If none exists:** do not open a PR. Post one comment on this issue with the version checked and the source locations inspected. Apply `status:blocked`, with the next action "recheck after an OpenCode upgrade".

### Phase 1 — implement using the capability found

- Reuse provider exhaustion detection from `.agents/plugins/opencode-aidevops/provider-rate-limits.mjs` and same-tier candidate selection from `.agents/plugins/opencode-aidevops/model-routing.mjs`. Do not add a second rate-limit parser.
- Follow the failover pattern in `.agents/plugins/opencode-aidevops/primary-entitlement-failover.mjs` (GH#37005): same tier only, never drop to a lower tier.
- Keep the `rate_limited=model@reset` blocker from `.agents/plugins/opencode-aidevops/subagent-effort-handlers.mjs` for the case where no candidate remains.

### Files Scope

- `.agents/plugins/opencode-aidevops/v2-provider-auth.mjs`
- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/plugins/opencode-aidevops/subagent-effort-handlers.mjs`
- `.agents/plugins/opencode-aidevops/model-routing.mjs`
- `.agents/plugins/opencode-aidevops/provider-rate-limits.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs`

### Scope Boundaries

- Do not patch or vendor OpenCode itself.
- Do not change routing for new children; #37654 already handles that.
- Do not cancel a child unless the parent is guaranteed a usable result.

## Acceptance Criteria

- [ ] Phase 0 outcome recorded on the issue: the capability found (version, hook, source location), or the absence evidence plus `status:blocked`.
- [ ] If implemented: a child stuck retrying on a fully rate-limited OAuth provider continues on the next routable same-tier model, and the parent receives that child's normal Task result.

  ```yaml
  verify:
    method: bash
    run: "node --test .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs .agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs"
  ```

- [ ] Regression: API-key providers, partially rate-limited pools, pinned agents, local-only sessions and the specialist advisor are never failed over, and failover never drops to a lower tier.
- [ ] The parent never receives a bare `Task cancelled` caused by this feature.
- [ ] `.agents/scripts/linters-local.sh --base-ref origin/main` passes, and the full plugin suite passes.

## Relevant Files

- `.agents/plugins/opencode-aidevops/v2-provider-auth.mjs:152` — current V2 retry hook (account rotation only)
- `.agents/plugins/opencode-aidevops/subagent-interrupted-task-receipts.mjs:28` — documents that `tool.execute.after` does not run for interrupted Tasks
- `.agents/plugins/opencode-aidevops/primary-entitlement-failover.mjs` — same-tier failover pattern to follow
- `.agents/plugins/opencode-aidevops/provider-rate-limits.mjs` — detects an exhausted OAuth pool (added in #37654)

## Dependencies

- **Blocked by:** an OpenCode host capability listed in Phase 0; it is absent in v1.19.5.
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Phase 0 capability check | 30m | inspect installed OpenCode source |
| Implementation | 3h | only if a capability exists |
| Verification | 1h | plugin suite plus a product-path run with a fake exhausted pool |
| **Total** | **~4.5h** | |
