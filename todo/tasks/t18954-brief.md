## Origin

- Created: 2026-11-10, interactive session (OpenCode, Build+), author: ai-interactive
- Trigger: maintainer let the paid OpenAI subscription lapse; the free OpenAI account still serves Luna at no cost, so Luna should keep routing for the simple tier and compaction.

## What

List `openai/gpt-6-luna` before `anthropic/claude-haiku-5-5` on the shipped simple tier. Standard and thinking stay Anthropic-primary (2026-11-04 decision unchanged). OpenCode compaction takes the first credentialed simple-tier candidate whose input limit fits, so it follows Luna too.

## Why

Request ledger (`~/.aidevops/.agent-workspace/observability/llm-requests.db`, `llm_requests`):

- Luna kept working on the current account after the subscription lapsed: 32 interactive-child requests on 2026-11-09 and 1 headless request on 2026-11-10, 0 errors.
- Compaction moved from Luna to Haiku 5.5 as sessions restarted on the Haiku-first table: 186 Haiku compactions on 2026-11-09 at ~107K average prompt, versus Luna handling 47–102 compactions/day on 2026-11-05..07.
- Free Luna use spends no Anthropic subscription quota, which is now the only paid capacity.

## How

- `.agents/configs/model-routing-table.json` and `.agents/configs/aidevops.defaults.jsonc` (tiers and `fallback_chains`): Luna first, Haiku 5.5 second; `_defaults` text records the decision.
- `.agents/scripts/shared-model-tier.sh`: static fallback order matches.
- `.agents/tools/context/model-routing.md`: tier table and a dated decision bullet.
- Tests that pinned the old order: `test-model-routing-overlay.sh`, `test-tier3-simplified.sh`, `test-specialist-advisor.mjs`.

## Acceptance

- `model_tier_candidates simple` lists Luna first. Headless `fallback-chain-helper.sh resolve simple` returns Luna only once the availability probe accepts ChatGPT-OAuth-only accounts (t18955, GH#37627); until then it falls back to Haiku 5.5.
- Installs with a custom `model-routing-table.json` simple-tier override keep their own order; reorder it there to adopt this change.
- Existing GH#36169 test: without OpenAI credentials, compaction falls back to Haiku 5.5.
- `node --test tests/test-model-routing.mjs tests/test-specialist-advisor.mjs` pass.
- Live check after deploy and session restart: ledger shows `routing_population='compaction'` rows on `gpt-6-luna` again, with no rise in Luna errors.

## Context

- Entitlement safety: a definite rejection (`model_not_found`, Codex "not supported") fails over to Haiku through the GH#36698 path for subagents and headless workers. Compaction has no such recovery (its model is fixed at config time); follow-up t18957. If free-tier Luna access ends before that lands, reorder the simple tier back to Haiku first.
- Not changed: standard/thinking order, reasoning levels, specialist advisor.

### Files Scope

- .agents/configs/model-routing-table.json
- .agents/configs/aidevops.defaults.jsonc
- .agents/scripts/shared-model-tier.sh
- .agents/tools/context/model-routing.md
- .agents/scripts/tests/test-model-routing-overlay.sh
- .agents/scripts/tests/test-tier3-simplified.sh
- .agents/plugins/opencode-aidevops/tests/test-specialist-advisor.mjs
- TODO.md
- todo/tasks/t18954-brief.md
