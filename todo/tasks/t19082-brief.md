## What

Headless worker model selection must apply the ChatGPT OAuth denylist
(`chatgpt_oauth_restrictions.openai_unsupported` in
`.agents/configs/model-routing-table.json`) the same way dispatch-side
resolution already does. Today the worker-side same-tier fallback can choose a
model that the routing table says this auth type cannot use.

Target repository: marcusquinn/aidevops

## Why

Worker capacity drops to zero when the Anthropic pool is unavailable and the
standard-tier fallback burns its retries on OpenAI models that the ChatGPT
OAuth account rejects.

Evidence from the runner's own logs (2026-11-16 22:00Z to 2026-11-17 05:14Z):

- `headless-runtime-metrics.jsonl`: 7 zero-worker spans of 25-62 minutes,
  about 5.6 hours in total. Every launch in that window failed in 14-29 s
  with `model_unavailable` on `openai/gpt-6.1-terra` (attempt 1,
  `routing_reason=headless_dispatch`) and then on `openai/gpt-6.1-sol`
  (attempt 2, `routing_reason=same_tier_fallback`). No attempt reached
  `opencode-go/deepseek-v4.1-flash`, the remaining standard-tier candidate.
  Worker logs from that period end with `All configured models are currently
  backed off` after the second rejection. That third-candidate filtering does
  not reproduce on the current code: a replay with Terra and Sol backed off
  and the Anthropic pool unavailable selects `opencode-go/deepseek-v4.1-flash`.
- Over the past 7 days the share of wall time with zero workers was 44.6%.
  Mean concurrency was 2.05 against a 20-worker target.
- The provider error was
  `The 'gpt-6.1-terra' model is not supported when using Codex with a ChatGPT account.`
  (HTTP 400, non-retryable).
- `pulse.log` shows the dispatcher resolving
  `standard -> openai/gpt-6.1-terra (candidate 3, primary anthropic/claude-sonnet-5-5 unavailable)`.
  That resolver (`model-availability-probe-lib.sh`) skips `gpt-6.1-sol`
  through `_chatgpt_oauth_denylist_check`. The worker-side fallback
  (`headless-runtime-model.sh`) does not call it, so it re-selects
  `gpt-6.1-sol`.
- Reproduction on this runner:
  `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai,opencode-go headless-runtime-helper.sh select --role worker --tier standard`
  prints `openai/gpt-6.1-sol`, although `gpt-6.1-sol` is in
  `openai_unsupported` and OpenAI auth is `oauth`.

GH#38713 / PR #38714 (merged 2026-11-17 06:48Z) already escalates learned
`model_unavailable` backoff. This change is the static half: a model the
routing table already marks as unsupported for this auth type is never
probed. After one `gpt-6.1-terra` rejection, the next same-tier choice is the
remaining healthy candidate. It no longer burns a second attempt.

## How

- `.agents/scripts/headless-runtime-model.sh` `get_configured_models()`:
  after the auth and OAuth-pool checks, skip `openai/*` models listed in
  `chatgpt_oauth_restrictions.openai_unsupported` when the OpenCode auth file
  records `openai.type == "oauth"`. Match exact IDs and dated snapshots
  (`<id>-YYYY-MM-DD`), as in
  `model-availability-probe-lib.sh:_chatgpt_oauth_denylist_check`.
  Selection (`_first_healthy_configured_model`,
  `_choose_worker_round_robin_model`) and the attempt budget
  (`_headless_route_attempt_budget`) all read this list, so they stay
  consistent.
- Read the denylist from the first routing table that defines it: the active
  table (`model_routing_table_path`, custom first), then the framework table
  (`model_routing_framework_table_path`). Custom tables usually omit
  `chatgpt_oauth_restrictions`. Read the auth type from `$OPENCODE_AUTH_FILE`,
  the same signal the dispatch-side resolver uses.
- Explicit `--model` pins are unchanged.
- Do not add `gpt-6.1-terra` to the static list. `gpt-6.1-sol` had 747
  successful worker sessions through 2026-11-03 before this account lost
  entitlement, so availability depends on the account. Learned rejections stay
  with GH#38713's escalating backoff.

### Files Scope

- .agents/scripts/headless-runtime-model.sh
- .agents/scripts/tests/test-headless-openai-routing.sh
- .agents/scripts/tests/test-headless-routing-retry.sh

## Acceptance

1. With OpenAI OAuth and the shipped routing table,
   `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai,opencode-go headless-runtime-helper.sh select --role worker --tier standard`
   no longer prints `openai/gpt-6.1-sol`.
2. When the OpenCode auth file records OpenAI as API-key auth, or has no
   OpenAI entry, `gpt-6.1-sol` stays selectable. The restriction applies only
   to ChatGPT OAuth, matching the dispatch-side resolver.
3. ShellCheck is clean for edited files.
   `.agents/scripts/tests/test-headless-routing-retry.sh`,
   `.agents/scripts/tests/test-headless-provider-round-robin.sh` and
   `.agents/scripts/tests/test-headless-openai-routing.sh` pass. The last
   asserted Sol selection under OAuth, so it moves to API-key auth for the
   allowlist and backoff cases and gains one OAuth denylist case.
4. Runtime check after deploy: during the next Anthropic pool outage,
   `headless-runtime-metrics.jsonl` shows no `openai/gpt-6.1-sol` worker
   attempts while OpenAI auth is OAuth.
