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
are denied; use native scoped tools or a local-only session. Phase 2 does not
introduce tool/network sandboxing; bound restrictions are described below.

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

## Tool-level egress (Phase 3)

The pre-tool hook gates execution before intent logging or OTEL enrichment.
While bound, host webfetch/websearch, direct image generation, unknown tools and
unknown MCP entries fail with a fixed content-free `VAULT_POLICY_DENIED`.
MCP classification uses copied type/URL fields from the trusted merged V1 config,
not tool arguments or registry defaults. Local processes and remote entries at
literal loopback remain allowed; non-loopback remote activation and tool calls
are refused. V2 snapshots resolved managed entries; unknown user entries deny.

### Shell mechanism

A network-command denylist is not a confinement boundary: interpreters, wrappers,
custom binaries and cleared environments bypass it. Instead, bound Bash and
bounded-operation starts accept only one literal, proxy/config-free curl form:

```bash
/usr/bin/curl --disable --noproxy '*' --proxy '' --max-time 30 --url 'http://127.0.0.1:11434/api/tags'
```

On NixOS the fixed system executable is `/run/current-system/sw/bin/curl`.
Plain `curl <literal-loopback-URL>` and its two-element argv are normalized to
this safe form before execution, so curlrc and proxy inheritance cannot leak.
The corresponding argv is accepted by bounded operations; restoration commands
are checked too. No redirects, additional options, shell composition, substitutions
or environment overrides are accepted. Existing command/workdir safety checks still
run. Already-running owned loopback listeners are reachable, but opaque local
listener startup and arbitrary local shell workflows remain denied until a verified
OS sandbox can allow those without external egress. This is a deliberate safety-stop
fallback, not a claim that the full owned-listener compatibility criterion is met.

### Helpers and telemetry

Remote embeddings, Groq/OpenAI transcription, transcription downloads, signature
LLM extraction, cloud email summaries, E-E-A-T scoring and video generation call
the shared shell runtime gate before sending. Generated embedding engines also
gate direct invocation. Regenerate pre-existing cached engines after deployment.
Local email-summary Ollama requests require literal loopback, ignore proxy settings
and refuse redirects. A refused remote fallback terminates rather than silently
retrying. Heuristic signature parsing remains available with
`EMAIL_PARSER_NO_LLM=true`; local transcription backends are unchanged.

OAuth pool/token health, static model registry/availability and health probes do
not send session content and do not need these provider-content gates. This
classification does not authorize model-initiated shell invocations of those tools.

The launcher disables OTEL before host SDK initialization in bound launches;
plugin enrichment is suppressed and the shell hook disables non-loopback OTLP
projection, including signal-specific endpoints. Direct host launches bypassing
the framework launcher must disable host instrumentation before startup themselves:
the plugin cannot revoke an exporter already initialized by trusted host code.

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
- Local MCP processes, their configuration and binaries are trusted executable
  code, not network-isolated: a local MCP that forwards content is equivalent to
  a loopback proxy. Only install/configure local-only services for bound work.
- Standalone shell helpers inherit an environment binding, not an immutable OS
  credential. Clearing it outside the plugin is outside enforcement. The Phase 1
  shell parser removes internal whitespace; malformed opt-out normalization remains
  pre-existing debt. New Python paths re-stamp a recognized binding before the shared
  gate so malformed values cannot authorize their remote requests.
- Not yet covered: active backend attestation, transcript persistence controls,
  unknown V2 user-local MCP classification, and sandboxed arbitrary local command/
  owned-listener startup. The parent remains open for these gaps.

The binding gates controlled tool execution; it is not an OS isolation mechanism.
