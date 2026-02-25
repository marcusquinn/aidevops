# t1330: Rate limit tracker for provider utilisation monitoring

## Origin

- **Created:** 2026-02-25
- **Session:** OpenCode:ouroboros-comparison
- **Created by:** human (ai-interactive)
- **Conversation context:** Reviewing Ouroboros budget tracking. User pointed out that with all-you-can-eat subscriptions, the real constraint is rate limits not dollars. No current tracking of requests/tokens per provider against rate limits. This is more useful than Ouroboros's dollar-based budget tracking.

## What

A rate limit tracking system that:
1. Monitors requests/min and tokens/min per provider from the existing observability DB (t1307)
2. Knows each provider's rate limits (from model registry or config)
3. Warns when approaching throttling thresholds (e.g., 80% of limit)
4. Informs model routing decisions — route to a different provider when one is near its limit
5. Exposes status via `aidevops stats rate-limits` or similar CLI

The user/system will experience: visibility into how close they are to rate limits across providers, and automatic routing away from throttled providers.

## Why

With subscription-based API access (no per-token billing), the constraint is rate limits, not cost. Currently we have zero visibility into rate limit utilisation. A provider hitting its rate limit causes failures with no proactive mitigation. This is the practical version of Ouroboros's budget tracking — adapted to our actual billing model.

## How (Approach)

1. Extend `observability-helper.sh` (t1307) to aggregate request counts per provider per time window
2. Add rate limit definitions to model registry or a new config file (`rate-limits.json` or extend existing model config)
3. Create `cmd_rate_limits()` in observability-helper.sh that shows current utilisation vs limits
4. Add a `check_rate_limit()` function that dispatch.sh / model-availability-helper.sh can call before routing
5. When a provider is at >80% of its rate limit, flag it as "throttle-risk" in model availability
6. Integrate with existing budget-aware routing (t1100) — rate limits become another routing signal

Key files:
- `.agents/scripts/observability-helper.sh` — LLM request tracking DB
- `.agents/scripts/model-availability-helper.sh` — model health/availability
- `.agents/scripts/supervisor/dispatch.sh` — model selection for tasks
- `.agents/tools/context/model-routing.md` — routing documentation

## Acceptance Criteria

- [ ] Rate limit definitions exist per provider (requests/min, tokens/min)
  ```yaml
  verify:
    method: codebase
    pattern: "rate.limit|requests_per_min|tokens_per_min"
    path: ".agents/scripts/"
  ```
- [ ] `aidevops stats rate-limits` (or equivalent) shows current utilisation per provider
- [ ] When a provider exceeds 80% of its rate limit, model routing prefers alternatives
- [ ] Rate limit data is derived from existing observability SQLite DB (no new data collection)
  ```yaml
  verify:
    method: codebase
    pattern: "observability.*db\\|llm_requests"
    path: ".agents/scripts/"
  ```
- [ ] Works with both token-billed and subscription providers
- [ ] ShellCheck clean
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/observability-helper.sh"
  ```

## Context & Decisions

- Inspired by Ouroboros budget tracking, but reframed for subscription billing model
- User explicitly noted: "we have all-you-can-eat subs with rate limits (and no limit:use tracking)"
- Build on existing observability DB (t1307) rather than new data collection
- Rate limits vary by provider and plan — must be configurable, not hardcoded
- 80% threshold is a starting point — should be configurable
- This complements t1100 (budget-aware routing) — rate limits are another routing signal

## Relevant Files

- `.agents/scripts/observability-helper.sh` — extend with rate limit tracking
- `.agents/scripts/model-availability-helper.sh` — integrate rate limit awareness
- `.agents/scripts/supervisor/dispatch.sh` — consume rate limit data for routing
- `.agents/tools/context/model-routing.md` — document rate limit routing

## Dependencies

- **Blocked by:** none (t1307 observability DB already exists)
- **Blocks:** nothing critical
- **External:** Provider rate limit documentation (varies by plan)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review observability DB schema, provider rate limit docs |
| Implementation | 2h | Rate limit config, aggregation queries, routing integration |
| Testing | 30m | Simulate high-usage scenarios |
| **Total** | **~3h** | |
