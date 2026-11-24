## What

When headless worker model selection returns 75 ("All configured models are currently backed off"), report **why each routing-table candidate was excluded**, and surface the same reasons in the Pulse dispatch skip line and in `aidevops status`.

## Why

Observed 2026-11-24 03:00–08:00Z on one runner: 529 Pulse dispatch candidates were skipped with `no selectable model in tier standard (every candidate backed off or unavailable)` (510 standard, 19 thinking); the dispatch-lock canary window had only 4 spawns. Root cause took hours to isolate because the message names no candidate or reason:

- `anthropic/claude-sonnet-5-5` — every OAuth pool account rate-limited;
- `openai/gpt-6.1-sol`, `openai/gpt-6.1-terra` — ChatGPT OAuth denylist (GH#38901, GH#39200);
- `opencode-go/deepseek-v4.1-flash` — excluded by a stale install-local `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=anthropic,openai` (set 2026-09-28, before GH#36714 made DeepSeek the standard fallback).

The allowlist silently turned the standard and thinking tiers into single-provider tiers once the OAuth denylist grew. Nothing warned. Each skipped candidate also spent ~36 s in the dispatch ceremony first.

## How

- `.agents/scripts/headless-runtime-model.sh`: add a read-only function that walks raw `model_tier_candidates` for a tier and classifies each model with the same filters `get_configured_models` / `_first_healthy_configured_model` / `_choose_worker_round_robin_model` apply, in the same order: `excluded_by_provider_allowlist`, `no_provider_auth`, `oauth_pool_exhausted`, `chatgpt_oauth_unsupported`, `backed_off`, else `selectable`. In `_choose_model_auto`, keep the existing `All configured models are currently backed off` warning text unchanged (log parsers/tests match it) and add one structured line `tier_selection_unavailable tier=<t> reasons=<model>=<reason>;...` plus a `hint=` when the allowlist excludes a configured candidate.
- `.agents/scripts/headless-runtime-helper.sh`: expose the classification as a read-only subcommand (e.g. `tier-coverage [--tier T]`) for status/diagnostics.
- `.agents/scripts/pulse-dispatch-worker-gates.sh` `_dlw_canary_preflight` rc 75 branch: append the latest `tier_selection_unavailable` reasons from the worker log to the existing `Skipping #N ... no selectable model` pulse.log line.
- `.agents/scripts/aidevops-cli/aidevops-status-lib.sh` allowlist section: warn when the allowlist excludes configured candidates and leaves a tier with one provider.

### Files Scope

- .agents/scripts/headless-runtime-model.sh
- .agents/scripts/headless-runtime-helper.sh
- .agents/scripts/pulse-dispatch-worker-gates.sh
- .agents/scripts/aidevops-cli/aidevops-status-lib.sh

## Acceptance

- With a copied OAuth pool whose Anthropic accounts are all rate-limited and `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=anthropic,openai`, `headless-runtime-helper.sh select --role worker --tier standard` still prints the existing warning and additionally names each candidate with its reason, including `opencode-go/deepseek-v4.1-flash=excluded_by_provider_allowlist`.
- Healthy selection output is unchanged (single model line on stdout).
- ShellCheck clean; existing headless-runtime and pulse canary tests pass.

## Verification

`shellcheck` on changed scripts; run existing `tests/test-headless-runtime*` and pulse canary preflight tests; reproduce with the copied-pool method above (never write the live pool).
