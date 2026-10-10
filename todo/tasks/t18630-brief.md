# t18630: GH#34125 Phase 1 — enforce operator-bound local-only egress gate in interactive OpenCode sessions

## Origin

- **Created:** 2026-10-09
- **Created by:** ai-interactive (maintainer-approved review of #34125)
- **Parent task:** #34125
- **Conversation context:** Maintainer review of #34125 verified that the documented Vault `local-only` contract is enforced only before headless dispatch (`vault-data-policy-helper.sh`); interactive OpenCode sessions have no deterministic gate. The maintainer approved and requested full-loop; this is the first phase.

## What

An operator can bind an interactive OpenCode session to local-only processing at launch (`AIDEVOPS_RUNTIME_POLICY=local-only` | `local-llm-only` | `local-ai`). When bound, every model request whose provider is not local fails closed with a content-free `VAULT_POLICY_DENIED` before any bytes leave the device. Routing never falls back to a non-local provider.

## Why

`reference/vault.md`, `tools/context/model-routing.md` ("Privacy policy still fails closed") and `reference/agent-routing.md` promise fail-closed local-only behaviour, but interactive sessions only have prose. A cloud parent session can read protected data or continue after a local backend fails.

## Tier

`tier:standard` — trust-boundary decision is fixed by this brief; requires independent security review before merge.

## How (Approach)

- **Binding (trust boundary, `#aidevops:trust-boundary`):** new `.agents/plugins/opencode-aidevops/local-only-policy.mjs`. Read `AIDEVOPS_RUNTIME_POLICY` once at plugin init from the launch environment and freeze the result (pattern: `team-interface-context.mjs` `loadTeamInterfaceConversation` + `deepFreeze`). Model output, tool args, chat text and later `process.env` mutation cannot set or clear it. Unrecognised non-empty values bind fail-closed.
- **Shared local-provider definition:** new `.agents/configs/local-ai-providers.conf` (one provider ID per line), read by both the plugin and `vault-data-policy-helper.sh` `_vault_policy_is_local_model`. Same initial set as today: `local ollama llama llama.cpp llamacpp`. A missing file means nothing is local (fail closed).
- **Egress gate V1:** first statement of `chat.params` in `index.mjs` (main hooks and `createConversationHooks`). OpenCode `Plugin.trigger` runs hooks through `Effect.promise`, so a throw aborts the request before the provider stream (`packages/opencode/src/session/llm/request.ts`, `src/plugin/index.ts`). This covers parent turns, subagents, compaction and resumed sessions.
- **Egress gate V2:** `v2.mjs` — assert in the `session.hook("context")` transform and before `providerAuth.httpRequest` in `session.hook("http.request")`.
- **Destination (security review):** provider IDs are operator-named, so a remote endpoint could sit under `ollama`. `chat` and `http` surfaces also require a literal loopback endpoint: V1 uses OpenCode `resolveSDK` precedence (non-empty `provider.options.baseURL`, else `model.api.url`); V2 uses the outgoing `Request.url`. V2 throw semantics verified at tag `v2.0.3`: `packages/plugin/src/promise/adapter.ts` wraps session hooks in `Effect.promise`, and `packages/core/src/session/model-request.ts` triggers `http.request` before `handler(sent)` in the shared prepare path (primary, compaction, generate, title); registering it also keeps providers off WebSocket transport.
- **Routing:** `selectConnectedRoutingCandidate` in `model-routing.mjs` skips non-local candidates when bound; an empty result returns `""` (callers already treat that as "no routed model").

### Files Scope

- `.agents/plugins/opencode-aidevops/local-only-policy.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/plugins/opencode-aidevops/model-routing.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-local-only-policy.mjs`
- `.agents/configs/local-ai-providers.conf`
- `.agents/scripts/vault-data-policy-helper.sh`
- `.agents/scripts/ai-research-helper.sh`
- `.agents/scripts/opencode-launcher-helper.sh`
- `.agents/reference/vault.md`
- `.agents/reference/vault-local-only-binding.md`
- `.agents/private-local-ai.md`

### Scope Boundaries

**Hard boundaries:** unbound sessions must behave exactly as today. No readiness probing, tool-read denial, MCP/OTEL/transcript scrubbing or Task delegation gating (Phases 2–3). No new authorization store.

**Integration scope recovery (implementation):** `ai-research-helper.sh` added. The plugin's own `ai-research` tool calls the Anthropic API directly with `curl`, bypassing `chat.params`; the helper now calls the shared `vault_runtime_policy_check` before either provider path. Other helpers that call provider APIs directly, and Bash-level egress by the model, remain Phase 3. `opencode-launcher-helper.sh` added: with a `managed` service route, `aidevops opencode` attached to the persistent shared server, whose plugin never sees the launch binding, so a bound launch silently ran unbound (reproduced on a managed-route host). Bound launches now stay direct, and bound `managed`/`attach`/`desktop` launches are refused.

## Acceptance Criteria

- [ ] Bound session (`AIDEVOPS_RUNTIME_POLICY=local-only`) with a non-local provider: `chat.params` throws `VAULT_POLICY_DENIED` and a synthetic sentinel in the request is never passed to a fake external provider.
- [ ] Bound session with a local provider (`ollama/*`): request proceeds unchanged.
- [ ] Unbound session: no behaviour change for any provider (regression guarantee).
- [ ] Binding cannot be cleared after init by mutating `process.env`.
- [ ] Bound routing never selects a non-local candidate; empty → `""`.
- [ ] Bound session with a remote, LAN, `0.0.0.0` or templated endpoint under a local provider ID is refused before send.
- [ ] Bound `aidevops opencode` never attaches to a shared server; bound `managed`/`attach`/`desktop` launches are refused.
- [ ] Headless gate unchanged: `bash .agents/scripts/tests/test-vault-data-policy-routing.sh` passes.

## Dependencies

- **Blocks:** Phase 2 (readiness + stop-and-notify in `tool.execute.before`), Phase 3 (MCP/OTEL/transcript/Task delegation surfaces) — filed after this binding interface lands.
