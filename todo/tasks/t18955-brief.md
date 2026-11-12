## Origin

- Created: 2026-11-10, interactive session (OpenCode, Build+), author: ai-interactive
- Trigger: while verifying t18954 (Luna-first simple tier), headless resolution still skipped Luna on an account that OpenCode serves Luna on.

## What

Make headless availability for `openai/*` reflect the inference path OpenCode actually uses with ChatGPT OAuth, so a free ChatGPT account that can run Luna is not reported as `key-invalid`.

## Why

Observed on 2026-11-10 (paid OpenAI subscription lapsed, free ChatGPT account remains):

- `opencode run -m openai/gpt-6-luna "Reply with exactly: LUNA_OK"` returned `LUNA_OK`.
- `model-availability-helper.sh check openai/gpt-6-luna --force` printed `openai: API key invalid (HTTP 403)` twice, then `env key rejected (HTTP 401/403); OpenAI OAuth API verification failed`.
- So `fallback-chain-helper.sh resolve simple` skips Luna (`openai/gpt-6-luna: unavailable, trying next`) and headless simple workers use Haiku 5.5, even though interactive subagents and compaction can use Luna at no cost.

`_probe_openai_oauth_fallback_verified` (`.agents/scripts/model-availability-probe-lib.sh`, ~L581) verifies the OAuth token by calling the OpenAI platform `/models` endpoint (`_probe_execute_http openai "$access_token"`). A ChatGPT-only account has no platform API access, so that check fails even though Codex-backend inference works.

## How

- `.agents/scripts/model-availability-probe-lib.sh`: replace or supplement the platform `/models` OAuth check with evidence from the path OpenCode uses for ChatGPT OAuth. Options to weigh: (a) a minimal Codex-backend probe; (b) treat a recent successful ledger request on that provider/model as health evidence; (c) rely on the existing headless model-level `model_unavailable` backoff (GH#36698) as the safety net.
- Keep the GH#24694 guarantee: quota-exhausted or entitlement-less OAuth accounts must not be marked healthy on token presence alone.
- Keep the t3555 rule: if OpenCode would use a rejected env `OPENAI_API_KEY` before OAuth, stay unhealthy.
- Reference pattern: `_probe_check_oauth_fallback` (~L623) and the t3229/t3555/GH#24694 cases in `.agents/scripts/tests/test-model-availability-oauth-probe.sh`.

## Acceptance

- On an account where `opencode run -m openai/gpt-6-luna` succeeds, `model-availability-helper.sh check openai/gpt-6-luna --force` exits 0, and `fallback-chain-helper.sh resolve simple` returns `openai/gpt-6-luna`.
- A quota-exhausted or entitlement-rejected OAuth account is still not healthy (GH#24694 regression stays green).
- Existing availability-probe tests pass; ShellCheck clean.

## Context

- Unknown: which non-env source supplied the rejected key (credentials.sh, gopass or env). Do not print key values; report only the source name.
- Interactive OpenCode routing and compaction already work (t18954 runtime check); this task only affects headless resolution.

### Files Scope

- .agents/scripts/model-availability-probe-lib.sh
- .agents/scripts/tests/test-model-availability-oauth-probe.sh
- TODO.md
- todo/tasks/t18955-brief.md
