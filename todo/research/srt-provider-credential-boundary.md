<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# SRT provider credential boundary and extraction-role envelope (t19190, GH#39364)

Parent: GH#35043. Status: **design only, decision-ready, awaiting operator approval.**
Revision 2 addresses the maintainer review on PR #39369 (OAuth subscription
allowances as the default credential source, relay network placement, pool
allowance accounting, stale macOS fact).

## Status statements (read first)

- **Nothing is enabled.** `AIDEVOPS_WORKER_EGRESS_BACKEND` is not set, no extraction role or relay exists, no inference was launched, and nothing here is approved until the operator says so on GH#39364.
- **No real key or token was handled** while producing this design. No secret store, OAuth pool file or `auth.json` was read, and no provider was contacted. No `probe` or `run` was executed. The only network action was `npm ci --ignore-scripts` in `.agents/scripts/worker-egress-srt/` (npm registry, lock-pinned) so the pinned SRT `dist` could be read, as the review requested. Claims about client behaviour that were not read in code are marked *unverified*.
- The deliverable ends at this PR. Building the relay, handling any token or key, adding a provider endpoint and enabling the backend are separate security and billing decisions.

## Evidence base (files read)

| Fact | Source |
| --- | --- |
| Backend supplies no provider auth, TLS interception or credential rewriting. It reports `synthetic-only` and `provider_connectivity: not-tested`; integration must use `required`, never `auto` | `.agents/reference/worker-egress-srt.md` "Checks and scope of a readiness result" |
| Policy is exactly one HTTPS/443 hostname from `network-tier-helper.sh export-provider-policy PROVIDER`; loopback, private and raw-IP are denied | same, "Contract and dependency"; `export_provider_backend_policy` in `.agents/scripts/network-tier-helper.sh` |
| The provider hostname comes from `providers.<name>.endpoint` in `configs/model-routing-table.json` (custom table wins) and must be a tier 1–3 exact entry in `configs/network-tiers.conf`. Today only `api.anthropic.com` and `api.openai.com` qualify; `chatgpt.com` is in neither file | `_provider_policy_domain`, `export_provider_backend_policy`; `rg -n -i chatgpt .agents/configs/network-tiers.conf .agents/configs/model-routing-table.json` |
| Platforms: Ubuntu x64, NixOS x64 **and macOS arm64** return `ready: true`, `synthetic-only`. Intel Macs are refused with `macos-x64-qualification-pending`; NixOS arm64 has no evidence | `worker-egress-srt.md` platform table and "macOS" (GH#38861, PR #39359); `backend.mjs` `main()` |
| Settings: `allowedDomains: [host:443]`, `strictAllowlist`, private-range `deniedResolvedAddresses`, no local binding, no Unix sockets; no `tlsTerminate`, `filterRequest`, `mitmProxy`, `parentProxy` or `credentials` today | `.agents/scripts/worker-egress-srt/backend.mjs` `settings()` |
| The child environment is wiped to `PATH`, `HOME` (= envelope `cwd`), `TMPDIR` (= host scratch), `LANG`, plus SRT-generated proxy variables | `backend.mjs` `cleanEnvironment()`, `wrappedArgv()` |
| Existing relay: host-side `127.0.0.1` server, random 32-byte capability key per invocation, one pinned model, only `POST /v1/responses`, `maxRequests` 1–256 (default 64), lifetime 1 s–1 h (default 30 min), 16 MiB request and 2 MiB response ceilings, one active request, `redirect: "error"`, stops on upstream 401/403/429, meters `response.completed` usage, fixed upstream `https://chatgpt.com/backend-api/codex/responses` | `.agents/scripts/frontier-harness-oauth-relay.mjs` `createRelay()` |
| The relay's caller selects one fresh OpenAI pool account once (`active`/`idle`, `expires` > now + 31 min, not cooling), reads no API-key variables and never rotates; the container gets only the relay URL and capability key | `.agents/scripts/frontier-harness-run.mjs`, `frontier-harness-run-support.mjs` `selectOAuthAccount()` |
| Pinned SRT 0.0.83 network options: `parentProxy` (upstream HTTP proxy URL), `mitmProxy` (per-domain CONNECT over a host Unix socket), `tlsTerminate` (in-process termination, ephemeral or supplied CA, **EXPERIMENTAL**), `filterRequest` (allow/deny plus `removeHeaders`/`setHeaders` and an `onResponse(status, headers)` observer), `refuseOpaqueTunnels`, `requireHostMatch`, `stripResponseHeaders`, `credentials` (env/file masking with sentinel substitution) | `node_modules/@anthropic-ai/sandbox-runtime/dist/sandbox/sandbox-config.js` `NetworkConfigSchema`, `CredentialsConfigSchema` |
| Route order is TLS termination > `mitmProxy` socket > `parentProxy` > direct. `tlsTerminate` and `mitmProxy` are mutually exclusive. `deniedResolvedAddresses` is **not** evaluated for `parentProxy` or `mitmProxy` routes | `dist/sandbox/http-proxy.js` CONNECT handler; `sandbox-manager.js` initialize; `deniedResolvedAddresses` description |
| CA trust variables (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, …) are exported to the child only for `tlsTerminate`, not for `mitmProxy` | `dist/sandbox/sandbox-utils.js` `CA_TRUST_VARS`, `generateProxyEnvVars()` |
| `setHeaders` first removes every header of the same folded name, then sets it; `onResponse` sees status and headers only, never the body | `dist/sandbox/request-filter.js` `applyHeaderEdits()`, `notifyResponse()` |
| SRT `credentials` masking substitutes sentinel→real in request **bodies** as well as headers, for every injectable host | `dist/sandbox/body-substitution.js` header comment; `sandbox-manager.js` `buildBodyCredentialInjector()` |
| Pool: accounts per provider with `access`, `expires`, `status` (`active`/`idle`/`rate-limited`/`auth-error`), `cooldownUntil`, `accountId`; refresh is a locked `lock → re-read → refresh → replace → unlock` transaction on the host | `.agents/plugins/opencode-aidevops/oauth-pool-storage.mjs`, `.agents/reference/oauth-token-state.md`, `oauth-pool-token-endpoint.mjs` |
| Anthropic OAuth request shape: `Authorization: Bearer`, `anthropic-beta` including `oauth-2025-04-20`, `anthropic-version`, CLI user agent, `x-api-key` removed, `?beta=true` on `/v1/messages`; body and stream transforms live in the client plugin | `.agents/plugins/opencode-aidevops/provider-auth-request.mjs`, `provider-auth-body.mjs`, `provider-auth-stream.mjs` |
| ChatGPT OAuth (Codex) rejects several model IDs that the models cache lists | `configs/model-routing-table.json` `chatgpt_oauth_restrictions` |
| Replay role: OpenCode only; `enforced` posture requires `AIDEVOPS_WORKER_EGRESS_MODE=required`; model must be non-Anthropic and allowlisted | `.agents/scripts/headless-runtime-launch.sh` `_validate_model_replay_execution_posture`, `_validate_model_replay_args` |
| Replay tools: read/grep/glob/write/edit/apply_patch on; bash/task/webfetch/websearch off; no MCP/LSP/formatter/share. `assertModelReplayEgressConfigured()` only checks for an executable absolute backend path | `.agents/scripts/model-replay-runtime.mjs` |
| Secret paths: `aidevops secret set NAME` (gopass preferred), `aidevops secret NAME -- cmd` injects into one subprocess | `.agents/reference/secret-handling.md` |

## 1. Credential boundary

### Requirements

1. Workload tools (read/grep/glob/write/edit/apply_patch, in the model client's process) cannot read a usable provider credential.
2. No usable credential reaches output, logs, transcripts or the output directory.
3. A credential the workload can see is useless outside this host and this invocation.
4. OAuth tokens are refreshed on the host only, never in the sandbox.
5. The policy rule stays "one exact hostname, HTTPS/443, from `export-provider-policy`". No parallel allowlist.

### Credential sources

| Source | Role | Supply path |
| --- | --- | --- |
| **OAuth subscription account from the aidevops pool** | **Default** for benchmark runs | Host launcher selects one account through the pool storage API (`getAccounts(provider)`, `selectOAuthAccount()` pattern) and makes sure its token is fresh via the pool's host refresh transaction. The token never touches the envelope, environment, argv or disk under any sandbox root. |
| Provider API key | Optional fallback, **off** unless the operator enables it with a spend cap (§6) | Operator stores it once with `aidevops secret set <NAME>` in their own terminal. The launcher receives it only through `aidevops secret <NAME> -- <host launcher>`. The design does not choose or read a key name. |

Both sources end in the same place: host process memory of the relay (§2), handed
over on an inherited pipe or descriptor that the backend reads once and closes
before any child is spawned. This is option C applied at the host launcher →
backend boundary, where no workload code runs; it is not applied to the workload.

### Mechanism options, re-run with "the workload holds a bounded local capability key"

The recommended mechanism generalises `frontier-harness-oauth-relay.mjs`: a
host-side relay holds the real credential, and the sandboxed client holds only a
random per-invocation **capability key**. The relay accepts that key from inside
this one sandbox for one pinned model, one method and path, a request cap and a
lifetime. It swaps the key for the real credential on the way out.

| | **A. Host relay + capability key (recommended)** | B. Short-lived scoped key in the sandbox | C. FD to the workload at exec time | D. SRT `credentials` masking |
| --- | --- | --- | --- | --- |
| What the workload can read | Capability key only | Real provider key | Real key in client memory; `/proc/self/fd/N` before close | Sentinel only |
| Works with OAuth subscriptions | **Yes**; refresh stays host-side | No: OAuth tokens cannot be scoped or capped like this | Only by moving the refreshing token into the sandbox, which breaks requirement 4 | Header swap only; no refresh, no model pin, no stop-on-limit |
| Value of a leaked credential | None after the run; during the run, usable only through this sandbox's own proxy | Full key until TTL or revocation | Full token until expiry | **Real value**: see below |
| Exfiltration to the allowed host | The capability key may appear in prompts; the provider cannot use it | Real key can be sent in a body and lands in provider logs | Same as B | Real value is sent if the sentinel appears in any request body |
| Fits one-host policy | Yes, with the placement in §2 | Yes | Yes | Yes |
| New code | Relay filter, launcher, qualification | Minimal | Launcher plus client change (*unverified* that OpenCode accepts an FD) | Configuration only |

**D is rejected.** In pinned SRT 0.0.83, masking substitutes sentinel→real in
request bodies as well as headers (`body-substitution.js`). A hostile workload can
put the sentinel it reads from its environment into a prompt. The real token then
travels to the provider as model input, and the model can echo it back into the
sandbox and the output directory. This is the "exfiltrated to the allowed host in
an unexpected form" case. Masking also gives no model pin, request cap or
stop-on-limit rule.

**B and C are not recommended.** B cannot carry OAuth subscription allowances at
all, and as an API-key fallback it exposes the real key to the workload. C puts
the refreshing token inside the sandbox. If the operator later allows the API-key
fallback, use it through A as well. B stays an experiment-only option for
non-sensitive inputs with a dedicated, capped, revocable key.

### Threat model for A

Assumed attacker: the model plus any content in the input (prompt injection),
acting only through the replay tool profile (no shell) inside the SRT sandbox.

| Can | Cannot |
| --- | --- |
| Read the capability key (environment or client config under `HOME`) and write it into output or into a prompt | Use the capability key off this host, after the run, or from any process outside this sandbox's proxy session. Use it for another model, path or method, or past the request cap or lifetime |
| Send allowed requests up to the cap, burning subscription allowance or (fallback) spend within the caps | Read the OAuth token or API key, which exist only in host relay memory and on the host→provider TLS leg |
| Send released inputs to the provider (that is the job) | Reach any other host (proxy 403), loopback, private ranges or raw IPs; open an opaque tunnel (refused with `refuseOpaqueTunnels`) |
| Trigger provider 401/403/429 on purpose to end the run early | Make the relay rotate to another account (stop is the rule, §3) or trigger a refresh inside the sandbox |
| Write attacker-chosen text into the output directory | Change its own usage record, which the host relay keeps outside the sandbox |

Residual risks: output stays untrusted (scan it with `prompt-guard-helper.sh` and
a literal check for the capability key before release). Provider-side retention
of released inputs is an operator question. Same-user host processes can read
relay memory, which is outside this boundary. SRT `tlsTerminate` is marked
EXPERIMENTAL upstream. The open backend gates (proxy resolved-address/redirect
and protocol bypass, hostile-descendant timeout per platform, attribution of
inherited macOS send rights) still apply.

## 2. Network placement of the relay

SRT denies loopback, and the strict allowlist admits only `<provider-host>:443`,
so the sandboxed client cannot reach a `127.0.0.1` relay. Pinned SRT 0.0.83 was
checked for each candidate placement (evidence table above).

| | (a) SRT proxy forwards to an external relay | (b) Bridged relay endpoint | (c) Relay inside the SRT host process (**recommended**) |
| --- | --- | --- | --- |
| SRT 0.0.83 support | **Exists.** `parentProxy` sends every non-MITM CONNECT to an HTTP proxy URL; `mitmProxy` sends CONNECTs for listed domains over a host Unix socket, "while SRT still handles allow/deny filtering" | No sandbox-facing bridge primitive beyond the HTTP/SOCKS bridge sockets; AF_UNIX creation is denied after seccomp | **Exists.** `tlsTerminate` + `filterRequest` run in the backend's own Node process, keyed to the allowed hostname |
| What the relay receives | An encrypted CONNECT tunnel. To inject headers it must itself terminate TLS: mint leaf certificates, run its own CA and get that CA trusted inside the sandbox. SRT exports CA trust variables only for `tlsTerminate`, so the backend would have to add them | A new sandbox-visible endpoint or socket | Parsed HTTPS requests after SRT's own termination, with SRT-managed CA trust |
| Can rewrite bodies or meter streamed usage | Yes; full control | Yes | **No.** Header edits only; `onResponse` gets status and headers, not the body. The body can be read for validation and denied, not changed |
| Resolved-address guard | **Skipped** by SRT for `parentProxy` and `mitmProxy` routes; the relay must repeat it | Depends on design | Kept: SRT dials the upstream itself |
| Upstream host authority | Relay dials outside SRT, so it must derive its single endpoint from the same exported policy bytes (`policy_sha256`) and refuse others | Same | The SRT allowlist from `export-provider-policy` is the only authority |
| New security-sensitive code | TLS termination, leaf issuance, CA lifecycle, CONNECT parsing, address guard | New bridge plus a sandbox surface needing its own qualification | One filter callback, plus the launcher handover |
| Qualification needed | Unix-socket relay mode 0600 and not under any sandbox root; CA key unreadable in the sandbox; resolved-address refusal; no other host reachable through the relay; `parentProxy` rejected (it applies to all hosts, uses a TCP loopback listener any local process can reach, and is taken from `HTTP_PROXY` if unset) | Full sandbox-surface qualification on each platform | SRT CA key unreadable in the sandbox; SOCKS and non-TLS CONNECT refused; Host/SNI mismatch refused; positive and negative checks in §7 on each qualified platform |

**Recommendation: (c).** It keeps one proxy, one allowlist authority, SRT's
resolved-address guard and SRT-managed CA trust, and it adds the least
security-sensitive code. The filter implements the relay contract:

- Allow only `POST` to the provider's one inference path (Codex: `/backend-api/codex/responses`; Anthropic: `/v1/messages`). Deny everything else on the host, including token and profile endpoints.
- Require `Authorization: Bearer <capability key>`, compared in constant time as `createRelay()` does, then `setHeaders` the real credential (and `chatgpt-account-id` for Codex). Strip `x-api-key` and any client credential.
- Read the request body (tee) and deny unless `model` equals the pinned model and the body has the expected shape. The existing relay forces `store: false` and `stream: true` for the Codex transport and defaults `instructions`; under (c) the client must send them itself, because the filter can deny but not rewrite.
- Count requests and enforce the cap and lifetime. In `onResponse`, set `disabled` on 401/403/429 so every later request is denied: the relay's stop rule.
- Set `refuseOpaqueTunnels: true`, `requireHostMatch: true`, `ambiguousRequestTarget: "refuse"` and `stripResponseHeaders: ["set-cookie"]`. Do not use the `credentials` block (§1 D).

**What (c) gives up, stated plainly:** host-authoritative token metering. The
filter sees status and headers, not `response.completed` events, and cannot
enforce the relay's 2 MiB response ceiling or keep exactly one stream active.
If the operator requires host-authoritative token counts (§6 decision 5), the
fallback is (a) with `mitmProxy` only, never `parentProxy`. The relay logic of
`frontier-harness-oauth-relay.mjs` then runs behind the Unix socket and adds the
TLS-termination and address-guard work listed above.

**Provider host authority.** The relay's upstream must stay under
`export-provider-policy`. For Anthropic that works today (`api.anthropic.com`).
For the Codex subscription transport it does not: `chatgpt.com` is neither a
routing-table provider endpoint nor a `network-tiers.conf` entry. The path is a
reviewed provider entry (for example a distinct Codex-subscription provider whose
`endpoint` is the Codex responses URL) plus an exact tier entry. That extends the
single authority, not a parallel list. `chatgpt.com` serves the whole ChatGPT web
app and is broader than `api.openai.com`, so the filter's single-path rule is
what narrows it. Adding the entry is a policy change for the operator (§6).

## 3. Account selection and allowance accounting

- **Selection.** The host launcher picks one account once, from an operator-approved subset of the pool (§6), using the `selectOAuthAccount()` rule: `active`/`idle`, not cooling, and `expires` later than run wall-time plus margin. If no account qualifies, stop. Never fall back to an API key unless the operator enabled the fallback.
- **Refresh.** Host only, before the run, through the pool's locked refresh transaction (`oauth-token-state.md`). The sandbox cannot reach token endpoints (not in policy, and denied by the filter path rule on the allowed host). No mid-run refresh in v1: a run that outlives its token stops with a recorded reason.
- **Rotation versus stop: stop.** One run uses one account. On 401/403/429 the relay disables itself, as `createRelay()` does, and the run ends with `stopped: subscription-limit|auth` and the account's cooldown recorded in the pool by the host. Rotating mid-run would mix accounts and plans within one measurement and hide allowance exhaustion, which breaks comparability. Rotation across *separate* runs is the pool's normal selection.
- **Per-run usage record** (host-written, outside the output directory, never the token): run id, provider, pinned model and settings, pseudonymous account id (hash of `poolAccountKey()`, not the email), credential source (`oauth-pool`/`api-key`), requests, upstream statuses, stop reason, wall time, `policy_sha256`, `envelope_sha256`, backend probe digest. Token counts: host-authoritative under placement (a). Under (c) they come from the client's session record and are marked `client-reported`. Any provider allowance headers seen by `onResponse` are recorded too; whether each subscription transport returns such headers is *unverified* and must be checked in qualification, not assumed.

### Per provider (verified in pool code)

| | OpenAI / Codex subscription | Anthropic subscription |
| --- | --- | --- |
| Exists | Pool OAuth login and refresh against `auth.openai.com`; `accountId` per account; a working relay transport (`frontier-harness-oauth-relay.mjs`) to `chatgpt.com/backend-api/codex/responses`, with body normalisation, usage metering and stop-on-limit; `selectOAuthAccount()`; model denylist in `chatgpt_oauth_restrictions` | Pool OAuth login and refresh (`claude.ai` authorize, `platform.claude.com/v1/oauth/token`); request shape in `provider-auth-request.mjs` (bearer, `oauth-2025-04-20` beta, CLI user agent, `?beta=true` on `/v1/messages`); body and stream transforms in `provider-auth-body.mjs` / `provider-auth-stream.mjs`; `api.anthropic.com` already exportable as a provider policy |
| Missing | Provider-policy entry and tier entry for the Codex host; a filter variant of the relay contract; confirmation that the in-sandbox OpenCode client sends Codex-compliant bodies with a placeholder token and never tries to refresh (*unverified*) | Any relay; a "relay mode" for the client plugin that uses the capability key, keeps its body transforms, and neither reads the pool nor refreshes. Placement (c) cannot do those transforms host-side. The replay launcher rejects `anthropic|claude` models, so Anthropic needs an explicit launcher policy change |

## 4. Extraction-role envelope

- **Runtime and client:** OpenCode, as `headless-runtime-launch.sh` requires (`headless_runtime=opencode`), running inside `run`. The existing `model-replay` role is the base; no new runtime.
- **Client credential configuration:** a provider entry whose API key or OAuth access value is the capability key, with a far-future placeholder expiry. It is written by the host into a 0600 file under the run's `HOME`, which is the output directory. The aidevops OAuth pool plugin must not run in the sandbox. Under (c) the base URL stays the real provider URL, because SRT terminates TLS for that host.
- **Tools:** keep the replay profile (read, grep, glob, write, edit, apply_patch on; bash, task, webfetch, websearch off; no MCP/LSP/formatter/share; subagent depth 0; `external_directory` deny). Least privilege for extraction is `read`, `grep`, `glob`, `write`. Shell stays off; that is what limits the workload to the tools above.
- **Invocation (never `auto`):**
  - Host side, set for this role's process only, never globally: `AIDEVOPS_WORKER_EGRESS_MODE=required`, `AIDEVOPS_WORKER_EGRESS_BACKEND=<absolute launcher for worker-egress-srt/backend.mjs>`, `AIDEVOPS_SRT_ENVELOPE=<operator-owned 0600 file>`, `AIDEVOPS_MODEL_REPLAY_EXECUTION_POSTURE=enforced`, provider listed in `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`.
  - `sandbox-exec-helper.sh` exports the `provider:NAME` policy, calls `probe` and refuses to start on failure in `required` mode; `run` wraps the OpenCode process tree.
  - **New gates needed:** (1) before a run, verify the probe reports `ready: true` and `synthetic-only` or better for the current platform, and bind `policy_sha256`/`envelope_sha256` to the run record. Today `assertModelReplayEgressConfigured()` only checks for an executable file. (2) The backend gains a credential-filter mode that refuses to start unless the credential handover descriptor, the pinned model and the caps are all present. (3) The envelope `timeoutSeconds` bound (1–60 s) must allow a model-run timeout class; that is a backend change (§6 decision 6).
- **Platform scope (corrected):** Ubuntu x64, NixOS x64 and macOS arm64 are qualified `synthetic-only` (`ready: true`). Intel Macs are refused (`macos-x64-qualification-pending`); NixOS arm64 has no evidence. On macOS, SRT `credentials` file masking degrades to deny, which does not matter because D is rejected. The `tlsTerminate` checks in §7 must run separately on each qualified platform; the synthetic qualification does not cover them.

## 5. Filesystem composition review (independent, design-time)

The envelope has exactly one output directory (`write`, initially empty, fresh per
run), `cwd` inside it, and operator-chosen `read` roots, at most 64 entries. The
backend refuses `/`, home, `/etc` and `/Users`, but does **not** claim other read
roots are safe. This is a **desk review of the specification and adapter**. It was
not run against a real extraction case, which needs the operator-supplied case.

| Class | Rule | Why |
| --- | --- | --- |
| Inputs | Read-only, copied to a per-run staging directory holding only the case's input files; never the original source tree | A bind of the original tree exposes siblings and `.git`; copy-in freezes content |
| Evaluator material (answers, gold labels, scoring scripts, rubrics) | Not in any `read` root and not co-located with inputs; check each root with `rg` for known identifiers | The model must not read the grader; a shared parent directory is the likeliest mistake |
| Sibling cases | Excluded; one case per run with its own staging directory | Cross-case contamination and leakage |
| Executable closures | Read-only, operator-owned, outside every writable root (backend enforces). Minimal closure; NixOS names store paths, never `/nix/store`; on Homebrew, `/opt/homebrew/opt` discloses installed package names (maintainer-accepted, GH#38861) | Writable closure means persistence; broad closure means ambient data |
| Client credential file | Only the capability-key config, 0600, under the output directory; never a pool file, `auth.json` from the host, gopass store or `credentials.sh` | The capability key is the only credential the sandbox may hold |
| SRT TLS CA | The CA certificate may be readable; the CA **key** must not be (the ephemeral CA directory is created under the backend's `TMPDIR`, the host scratch directory, which is not a read root) | A readable CA key would let the workload impersonate the provider to its own client, and would weaken the filter's guarantees |
| Symlinks | Staging contains none (`find -type l` is empty); `loadEnvelope()` realpaths `read` entries, but links inside a root may still point out | Verify with a canary before release |
| Ambient credentials | No `~/.config`, `~/.ssh`, `~/.aidevops`, pool files, cloud CLI state, `.env` or `.git` credentials under any root; `HOME` is the output directory | Any other credential in a read root defeats the boundary |
| Output | Single owned directory; the 8 MiB per-file cap is not an aggregate disk cap; treat it as untrusted | Quota is an operator decision |
| Writable overlap | No `read` root equals or contains the output directory or an ancestor | A later run could read earlier output; use fresh output per invocation |
| `/proc`, `/sys`, `/dev` | Confirm with a canary what read tools can list; only fds 0–2 may be open in the sandbox (the handover descriptor must be closed) | Direct consequence for the credential mechanism |

**Pre-release checklist for the operator's envelope** (each answer is yes/no with
command evidence): list the resolved `read` entries and match each against the
classes above; `rg` for evaluator and sibling identifiers across staging; `find`
symlinks and unexpected files; confirm output is empty and 0700; run the repository
secret scanner (`secretlint`) over staging.

**Residual finding:** the NixOS envelope holds 57 of 64 entries, so a nixpkgs bump
can push the closure past the bound. Adding the OpenCode runtime closure to the
envelope will use more of that margin. Treat `bounded-path-list-required` as the
signal to trim, never to raise the bound.

## 6. Operator decisions (listed, not made)

1. **Model and settings:** provider, model ID, effort/variant, limits. The launcher forbids Anthropic/Claude for replay, and Codex OAuth rejects some model IDs (`chatgpt_oauth_restrictions`).
2. **Subscription accounts for benchmarks:** which pool accounts (by pseudonymous id or label) may be used, per provider.
3. **Provider terms:** whether each subscription's terms permit automated benchmark use through a relay, including the CLI-identifying headers the Anthropic transport sends. This design lists the question; the operator decides.
4. **API-key fallback:** allowed at all or not; if allowed, which secret name, per-run and per-day spend cap, and who revokes.
5. **Placement and metering:** accept (c) with client-reported token counts, or require host-authoritative metering and fund placement (a) with `mitmProxy`.
6. **Wall-time:** the envelope allows 1–60 s per command; a model run needs a longer class (replay cells default to 3600 s with a guardian). Token freshness must cover it, since v1 does not refresh mid-run.
7. **Resource and allowance limits:** request cap and lifetime per run; CPU/RAM/aggregate disk (not capped by the backend); per-day allowance or spend ceilings; hard-stop rule.
8. **Provider policy change:** whether to add a Codex-subscription provider endpoint and an exact `chatgpt.com` tier entry.
9. **Input release:** which cases may go to which provider, under what data classification and retention terms. Nothing is released by this design.
10. **Comparison-attempt approval:** how many comparison runs across models, settings or accounts, and who approves each.
11. **Platform scope:** which qualified host runs the first case; whether Intel Macs and NixOS arm64 stay out.
12. **Evidence required before enabling:** which open backend gates (§1 residual risks) must close first.

## 7. Verification plan (to run only after approval)

### Positive

1. **Filter contract, no credential:** with a synthetic capability key and no real token, a request through `run` that has the right key, model and path reaches the provider and gets its 401. A wrong key, path, method or model gets the filter's 403 without any upstream call (`last_upstream_status` unchanged).
2. **Credential works end to end:** with one approved account, a single bounded inference request returns provider success and one usage record entry.
3. **No usable credential in the sandbox:** a canary under the replay-equivalent tool profile lists the environment, `HOME`, `TMPDIR`, `/proc/self/fd` and readable roots. It finds the capability key but no OAuth token, refresh token, API key or CA key, and only fds 0–2.
4. **Leak scan:** output, captured logs and the usage record contain no literal real token (checked host-side against the in-memory value, never printed) and no upstream `Authorization` value.
5. **Stop rule:** a provider 429 (or a simulated one in a unit test with an injected fetch) disables the filter; the next request is denied without an upstream call, and the pool records the cooldown host-side.
6. **Expiry:** after the lifetime or the request cap, requests are denied; after the run, the capability key is rejected because the backend process is gone.

### Negative

- Without the credential-filter mode, the same `run` still reaches the provider unauthenticated (HTTP 401), reproducing the existing qualification evidence. The client fails closed and does not fall back to a local key or `trusted-local`.
- SOCKS CONNECT and non-TLS CONNECT to the allowed host are refused (`refuseOpaqueTunnels`); a Host/SNI mismatch gets 421; a request to a second public host still gets the proxy 403.
- A request to the provider's token or profile endpoint on the allowed host is denied by the path rule, and no refresh happens inside the sandbox.
- With `AIDEVOPS_WORKER_EGRESS_MODE=auto`, or without a backend, the enforced replay posture refuses to start (`_validate_model_replay_execution_posture`).
- With the API-key fallback disabled, a missing or exhausted OAuth account stops the run; no key is read.

## 8. Proposed next steps if approved (each needs its own approval)

1. The operator answers §6 on GH#39364.
2. File implementation issues: backend credential-filter mode (placement (c)) with the descriptor handover; host launcher with pool selection, host refresh and the usage record; launcher qualification gate; Codex provider-policy entry if decision 8 approves it; client relay mode for Anthropic if decision 1 allows Anthropic; envelope-composition checker.
3. Qualify in order: synthetic key with a 401 path, then the §7 checks on one qualified Linux host, then one approved account on a non-sensitive case, then the other qualified platforms.
