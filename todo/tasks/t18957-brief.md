## Origin

- Created: 2026-11-10, interactive session (OpenCode, Build+), author: ai-interactive
- Trigger: CodeRabbit review on PR #37628 (t18954, Luna-first simple tier); verified locally that no entitlement recovery covers compaction.

## What

When OpenAI definitely rejects the compaction model (Luna) for the current account, recover compaction onto the next fitting, credentialed simple-tier candidate (Haiku 5.5) instead of leaving the session without a summary. Preserve explicit `agent.compaction` model/variant pins and local-only residency (GH#35893).

## Why

- Since t18954 the shipped simple tier, and therefore compaction, is Luna-first. A free ChatGPT account serves Luna today (live `opencode run -m openai/gpt-6-luna` returned `LUNA_OK` on 2026-11-10), but that entitlement can end without notice.
- `applyCompactionRouting` (`.agents/plugins/opencode-aidevops/compaction-routing.mjs`, ~L112) picks the model once at config time. It checks credential presence and input limit, not entitlement.
- `rg -n compaction` finds no match in `primary-entitlement-failover.mjs` or `openai-codex-model-fallback.mjs`: the GH#36698 rejection handling covers subagents and headless workers only.
- History: on 2026-11-03 Luna compaction hit 5 errors (expired auth) with no fallback.

## How

Options for the implementer to weigh (OpenCode 1.x reads the compaction model only from global agent config; see the GH#35893 comment above `allowedCompactionProvider`):

1. Make the compaction candidate filter consult the existing per-auth model rejection records written by the GH#36698 path (`openai-codex-model-fallback.mjs` / `primary-entitlement-failover.mjs`), so a rejected Luna is skipped, and set `config.agent.compaction` to the next fitting candidate when a rejection is recorded.
2. On a compaction-agent error with a definite entitlement signature (`model_not_found`, Codex "not supported when using Codex with a ChatGPT account"), record the rejection and re-run compaction on the next candidate if the runtime allows it in-process.

Reference tests: compaction cases in `.agents/plugins/opencode-aidevops/tests/test-model-routing.mjs` (GH#32934, GH#36169, GH#35893).

## Acceptance

- With a recorded definite Luna rejection for the current OpenAI auth, the compaction route resolves to `anthropic/claude-haiku-5-5` (when credentialed and fitting); with no rejection it stays Luna.
- Explicit compaction pins and local-only residency behave as before (existing tests pass).
- Non-entitlement errors (rate limit, transient 5xx, expired token) do not trigger a permanent switch.
- `node --test .agents/plugins/opencode-aidevops/tests/test-model-routing.mjs` passes.

## Context

- Unknown: whether OpenCode 1.19 exposes any in-process path to retry a failed compaction with a different model; option 1 avoids needing it.

### Files Scope

- .agents/plugins/opencode-aidevops/compaction-routing.mjs
- .agents/plugins/opencode-aidevops/openai-codex-model-fallback.mjs
- .agents/plugins/opencode-aidevops/primary-entitlement-failover.mjs
- .agents/plugins/opencode-aidevops/tests/test-model-routing.mjs
- TODO.md
- todo/tasks/t18957-brief.md
