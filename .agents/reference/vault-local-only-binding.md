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

## Protected reads and local failure visibility (Phase 2)

The operator may classify roots with a mode-600, current-user-owned JSON file at
`~/.config/aidevops/local-only-roots.json` (or the launch `XDG_CONFIG_HOME`):

```json
{ "roots": ["/absolute/operator-selected/protected-root"] }
```

All listed roots have the strict `local-LLM-only` processing label. This list is
classification, not a parallel authorization store; existing secret and source
permissions still apply, including in bound sessions. Vault's storage gate does
not currently expose a path-to-processing-label registry, so no Vault collection
is silently assigned this label. Configure every plaintext root that requires it.

The plugin snapshots the list before tools run. A missing list leaves unclassified
reads unchanged; malformed, symlinked, unreadable or insecure configuration denies
read tools content-free. Restart after operator classification changes. Model
output, read contents, tool arguments and later environment changes cannot change
the active classification or binding. Direct write/patch targets for the list are
refused, including relative targets and symlink aliases.

Unbound Read/Grep/Glob/list operations on classified paths, their aliases or
containing search directories fail before intent/provenance hooks or tool execution
with `VAULT_POLICY_DENIED` and the local-only relaunch command. Bash and bounded
operation starts use the same gate. With configured roots, unbound shell reads
are deliberately restricted to a single literal `cat`, `head`, `tail`, `wc`,
`ls`, `stat` or `pwd` command with no options. Opaque programs, interpreters,
substitutions, pipelines and executable reader options cannot be proven safe and
are denied; use native scoped tools or a local-only session. Bound shell behavior
is otherwise unchanged: this phase does not introduce tool/network sandboxing.

In bound sessions, `session.error` for a local HTTP 404, refused connection,
timeout, model-identity mismatch or `VAULT_POLICY_DENIED` produces a foreground
content-free toast and bounded receipt, once per session per 30 seconds. Receipts
are recorded even headlessly or when the TUI is unavailable; a persistence failure
never permits the blocked operation and is reported without error/path content.
The append-only, mode-600 log is
`~/.aidevops/.agent-workspace/private-processing-blockers.jsonl`, bounded to 1 MiB
by the shared blocker logger. Only fixed check/operation names and validated session
IDs are supplied; ambient worker repository/request metadata is suppressed.

Readiness uses the launch binding and Phase 1 request checks, not model claims.
No additional health probe is made: a successful local parent turn demonstrates
availability, not service attestation; another probe cannot prove the service will
not forward data. Later backend failures abort through the host's existing error
path, notify the operator and never authorize remote fallback.

## Trust assumptions and gaps

- The loopback check trusts the service at that port: a local proxy that
  forwards to a remote API, or a remapped `localhost` in `/etc/hosts`, is
  outside the check.
- Other installed OpenCode plugins run in the same process and are trusted
  code: one could rewrite a request after the aidevops hook approves it, or send
  data itself. Install only plugins you trust for local-only work.
- The operator configuration and launch environment are trusted. Same-user
  arbitrary code or bound Bash can alter files for a future launch; the current
  frozen policy is unchanged. Review classification before relaunching after
  running untrusted code. This is not an OS isolation or attestation mechanism.
- Not yet covered (later GH#34125 phases): active backend attestation,
  MCP output, observability/transcript persistence,
  helpers that call provider APIs without the shared gate, and network egress
  the model starts through Bash (for example `curl`, or a helper run with the
  variable cleared).

The binding keeps the session's own model traffic on the device; it is not yet
a sandbox for tools.
