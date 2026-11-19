<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `gpt-6.1-terra chatgpt oauth unsupported` → 0 relevant hits.
- [x] Discovery pass: no open issue or PR mentions `gpt-6.1-terra` or changes `openai_unsupported` (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:simple` — one denylist entry and one test expectation.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (worker throughput investigation)
- **Conversation context:** From 2026-11-16 to 2026-11-19, 67 OpenCode sessions on one runner failed on their first request with `APIError: The 'gpt-6.1-terra' (or 'gpt-6.1-sol') model is not supported when using Codex with a ChatGPT account`; 40 were `gpt-6.1-terra`. `llm_requests` holds zero successful OpenAI requests for either model since 2026-11-05. `gpt-6.1-sol` is already in `chatgpt_oauth_restrictions.openai_unsupported` and its failures stopped by 2026-11-18. `gpt-6.1-terra` is not, and failed 10 more times between 2026-11-18T19:38Z and 2026-11-19T00:00Z. Its `provider_backoff` row was still at the 3600 s base, so the probe rediscovers the rejection every hour.

## What

Add `gpt-6.1-terra` to `chatgpt_oauth_restrictions.openai_unsupported` in the routing table, so worker selection and the availability probe skip it while OpenAI auth is ChatGPT OAuth. API-key auth still routes it.

## Why

A permanent entitlement rejection should not cost a probe or launch attempt every hour. This matches how `gpt-6.1-sol` was handled (GH#37040, GH#38901).

## Tier

`tier:simple`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/configs/model-routing-table.json:72-73` — add `gpt-6.1-terra` to `openai_unsupported` and the evidence to `_comment`.
- EDIT: `.agents/scripts/tests/test-headless-openai-routing.sh:102-115` — under OAuth, the standard tier no longer selects `openai/gpt-6.1-terra`; expect no OpenAI candidate (exit 75), the same as the thinking tier.

### Files Scope

- `.agents/configs/model-routing-table.json`
- `.agents/scripts/tests/test-headless-openai-routing.sh`

### Reference pattern

- The `gpt-6.1-sol` entry in the same list (GH#37040).

## Acceptance Criteria

- [ ] `jq -e '.chatgpt_oauth_restrictions.openai_unsupported | index("gpt-6.1-terra")' .agents/configs/model-routing-table.json` succeeds.
- [ ] `bash .agents/scripts/tests/test-headless-openai-routing.sh` passes with the updated OAuth expectation; API-key routing tests unchanged.
- [ ] After deploy, `headless-runtime-helper.sh backoff status` shows no new `openai/gpt-6.1-terra|model_unavailable` row over 24 h.
