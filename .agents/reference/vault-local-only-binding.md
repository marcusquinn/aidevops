<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Vault Local-Only Session Binding (GH#34125)

Task metadata cannot protect an interactive session, so the operator binds it at
launch:

```bash
AIDEVOPS_RUNTIME_POLICY=local-only aidevops opencode
```

`local-LLM-only` and `local-ai` are equivalent. Unset, `provider-ai`,
`provider-allowed` and `provider-ai-approved` leave the session unbound; any
other value, including typos and `hybrid`, binds fail-closed.

## Launch

The binding exists only in the launching process environment. A bound launch
therefore always runs a direct session: `opencode-launcher-helper.sh` skips the
managed shared-server route and refuses `managed`, `attach` and `desktop`
launches, whose plugin runs in another process without the binding.

## Enforcement while bound

The OpenCode plugin (`plugins/opencode-aidevops/local-only-policy.mjs`) reads the
binding once at init and freezes it; model output, tool arguments and later
environment changes cannot clear it.

- Every model request to a provider not listed as local fails with
  `VAULT_POLICY_DENIED` before sending: V1 `chat.params` (parent turns,
  subagents, compaction, resumed sessions) and V2 `context`/`http.request`.
  OpenCode runs these hooks through `Effect.promise`, so a throw aborts the
  request before the transport sends (V2 verified at tag `v2.0.3`).
- The endpoint must also be literal loopback (`localhost`, `127.0.0.0/8`,
  `[::1]`). V1 checks a non-empty `provider.options.baseURL`, else
  `model.api.url`, matching OpenCode's SDK resolution; V2 checks the outgoing
  request URL. A remote endpoint configured under a local provider name, a LAN
  inference host, `0.0.0.0` or an unresolved `${VAR}` URL is refused.
- Tier routing selects only local candidates and never falls back to a remote
  provider; with no local candidate, subagent routing stops.
- Child processes inherit the variable, so `vault-data-policy-helper.sh`
  (headless dispatch) and `ai-research-helper.sh` deny remote models too.

Local provider IDs are listed once in `configs/local-ai-providers.conf`, shared
by the plugin and `vault-data-policy-helper.sh`; a missing list means nothing
is local. Denials never include prompt content or the endpoint URL.

## Trust assumptions and gaps

- The loopback check trusts the service at that port: a local proxy that
  forwards to a remote API, or a remapped `localhost` in `/etc/hosts`, is
  outside the check.
- Other installed OpenCode plugins run in the same process and are trusted
  code: one could rewrite a request after the aidevops hook approves it, or send
  data itself. Install only plugins you trust for local-only work.
- Not yet covered (later GH#34125 phases): local-backend readiness checks,
  protected-read denial, MCP output, observability/transcript persistence,
  helpers that call provider APIs without the shared gate, and network egress
  the model starts through Bash (for example `curl`, or a helper run with the
  variable cleared).

The binding keeps the session's own model traffic on the device; it is not yet
a sandbox for tools.
