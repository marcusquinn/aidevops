<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# SRT provider credential boundary and extraction-role envelope (t19190, GH#39364)

Parent: GH#35043. Status: **design only, decision-ready, awaiting operator approval.**

## Status statements (read first)

- **Nothing is enabled.** `AIDEVOPS_WORKER_EGRESS_BACKEND` is not set, no extraction role exists, no inference was launched, and nothing in this document is approved until the operator says so on GH#39364.
- **No real key was handled** while producing this design. No secret store was read, no provider was contacted, and no probe or run was executed. Every claim about code comes from reading the files listed under Evidence; claims about SRT internals that were not read are marked *unverified*.
- Deliverable ends at this PR. Implementation, key handling and enabling the backend are separate security and billing decisions.

## Evidence base (files read)

| Fact | Source |
| --- | --- |
| Backend supplies no provider auth, no TLS interception, no credential rewriting; qualification is `synthetic-only`, `provider_connectivity: not-tested`; any integration must use `required`, never `auto` | `.agents/reference/worker-egress-srt.md` "Checks and scope of a readiness result" |
| Policy is exactly one HTTPS/443 hostname from `network-tier-helper.sh export-provider-policy PROVIDER` | same, "Contract and dependency" |
| Child env is wiped; only `PATH`, `HOME` (= envelope `cwd`), `TMPDIR`, `LANG` plus SRT-generated proxy vars survive | `.agents/scripts/worker-egress-srt/backend.mjs` (env clearing near line 339; proxy vars near line 205) |
| `required` mode fails closed when the backend path is not absolute/executable; `provider:NAME` profile exports the provider policy | `.agents/scripts/sandbox-exec-helper.sh` `_sandbox_resolve_egress_backend`, `_sandbox_prepare_worker_egress` |
| Replay role: OpenCode only, `enforced` posture demands `AIDEVOPS_WORKER_EGRESS_MODE=required`; `trusted-local` demands `auto` and no backend; non-Anthropic provider; provider must be in `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`; built-in auth plugins must stay enabled; ten `OPENCODE_DISABLE_*`/`PURE` toggles must be `1` | `.agents/scripts/headless-runtime-launch.sh:470-595` |
| Replay tool profile: `*` false; read/grep/glob/write/edit/apply_patch true; bash/task/webfetch/websearch false; no MCP, LSP, formatter, share | `.agents/scripts/model-replay-runtime.mjs:66-102` |
| `assertModelReplayEgressConfigured()` only checks that the backend is an absolute executable file; it does not check mode, qualification fields or that the backend is SRT | `model-replay-runtime.mjs:47-55` |
| Secret paths: `aidevops secret set NAME` (gopass preferred, `systemd-creds`/`credentials.sh` fallbacks), `aidevops secret NAME -- cmd` injects into one subprocess | `.agents/reference/secret-handling.md` |

## 1. Credential boundary

### Requirements

1. The workload's tools (read/grep/glob/write/edit/apply_patch, running in-process in the model client) must not be able to read the key.
2. The key must not reach output, logs, transcripts or the output directory.
3. The key must be usable only against the allowed provider host and, ideally, only for the intended calls.
4. No change to the policy rule "one exact hostname, HTTPS/443".

### Options

| | A. Host-side injection (recommended) | B. Short-lived scoped key in the sandbox | C. FD passed at exec time |
| --- | --- | --- | --- |
| Mechanism | A small host-side forwarder outside the sandbox holds the key, adds the auth header and relays to the single provider host. Client in the sandbox holds only a placeholder key. | Operator mints a key with narrow scope, short TTL and a spend cap; delivered to the client in the child environment or a file under `cwd`. | Host opens the secret on an inherited descriptor; the client reads it at startup and closes it. |
| Key visible to workload tools | **No.** Never enters the sandbox. | **Yes.** Read tool can open `/proc/self/environ` or the file; model can then echo it into output. | Partly. After close it is in client process memory only; before close any in-process tool could read `/proc/self/fd/N`. OpenCode's own auth plugin path must accept an FD, which is *unverified* and probably needs a patch. |
| Exfiltration to allowed host | Impossible for the key; the workload can only make provider requests that the forwarder already permits. | Possible: put the key in a request body or prompt to the provider host. Blast radius limited by scope, TTL and cap, but the key lands in provider logs. | Same as B once read into memory. |
| TLS | The sandbox must reach the forwarder, not the provider directly. Needs a design for how the client addresses it (see open question below). Forwarder does its own TLS to the provider, so no MITM of the client. | Unchanged: client does TLS to the provider through the SRT proxy. | Unchanged. |
| New code | Yes: forwarder, bridge into sandbox, tests. This is an implementation task. | Minimal: env or file passing. | Moderate: launcher change plus client compatibility. |
| Fits "provider-only egress" policy | Needs the policy host to be the forwarder endpoint, or the proxy to rewrite; either alters or extends the one-hostname rule. | Fits exactly. | Fits exactly. |

**Open question for A (decide before building).** The SRT bridge exposes only the SRT HTTP/SOCKS proxy to the child, and AF_UNIX creation is denied by seccomp. The forwarder therefore has two candidate placements: (a) an SRT-level hook that injects the header for the allowed host after the CONNECT, which requires TLS termination and is *unverified* in pinned SRT 0.0.83 (the adapter does not use any MITM option today); or (b) a second bridged loopback endpoint, which widens the sandbox network surface and needs its own qualification. Neither is available without code. If neither can be qualified, the fallback is B.

### Recommendation

- **Target: A.** It is the only option that meets requirement 1 outright.
- **Interim, if the operator wants a first experiment before A exists: B with all of** — a key dedicated to this experiment, restricted to the approved model, an enforced spend cap, TTL of at most the wall-time limit plus margin, and revocation as a verification step. B is accepted only for non-sensitive inputs because a hostile workload can read it. Do not use a general-purpose or long-lived key.
- **C is not recommended** unless the client is shown to accept an FD without a patch.

### Threat model (what a hostile workload can and cannot do)

Assumed attacker: the model plus any content in the input (prompt injection), acting through the replay tool profile only (no shell).

| Option | Can | Cannot |
| --- | --- | --- |
| A | Send arbitrary provider requests through the forwarder (burning budget within the forwarder's caps); write attacker-chosen text into the output directory. | Read the key; reach any other host (proxy 403, per qualified canary); use the key after the run ends if the forwarder dies with it. |
| B | Everything in A; additionally read the key and leak it in output or to the provider; keep using it until TTL or revocation. | Reach non-provider hosts; use the key outside its scope, cap and TTL. |
| C | Same as B after the client has read it, if an in-process tool can read memory or descriptors. | Same as B. |

Residual risks common to all: output-directory content is untrusted and may contain the key under B/C, so scan output before it leaves the owned directory (`prompt-guard-helper.sh` for injection; a literal-match check against the key for leakage); provider-side data retention of released inputs; open qualification gaps in the backend doc (proxy resolved-address/redirect and protocol bypass, hostile descendant timeout per platform, macOS DNS/IPC hold).

### Secret supply path (existing aidevops mechanisms only)

- Operator stores the value once: `aidevops secret set <NAME>` in their own terminal (hidden prompt, gopass preferred). Never in chat, issue, envelope, policy file or command line.
- The launcher on the host reads it at run time through the subprocess-scoped form (`aidevops secret <NAME> -- <host-side command>`), so it lives only in the host-side process: the forwarder for A, or the one-shot file/env construction for B. The envelope file (0600, operator-owned) must not contain it.
- The key name is chosen by the operator; this design does not pick one or read any existing entry.

### Verification (positive, to run only after approval)

1. Forwarder (A) or key (B) probe: a single bounded request through `run` returns provider success (HTTP 200 on a models/list-style call), proving the credential works end to end through the qualified boundary.
2. Inside the sandbox, a synthetic workload that runs the *replay tool profile equivalent* (read `/proc/self/environ`, list `cwd`, `HOME`, `TMPDIR`, mounted paths) shows no key material for A; for B record that it is readable (this is the accepted risk).
3. Output directory and captured logs after a run are grepped for the literal key and for the `Authorization` prefix: zero matches for A.
4. A request to a second public host still returns proxy 403 with the key configured.
5. After the run, the forwarder process is gone and (B) the key has been revoked, confirmed by a request that returns 401.

### Verification (negative)

- With the credential mechanism absent, the same `run` reaches the provider only unauthenticated (HTTP 401), reproducing the existing qualification evidence; the client must fail closed, not fall back to a local key or to `trusted-local`.
- With `AIDEVOPS_WORKER_EGRESS_MODE=auto`, or no backend, the enforced replay posture refuses to start (`_validate_model_replay_execution_posture`).

## 2. Extraction-role envelope

- **Runtime and client:** OpenCode, as `headless-runtime-launch.sh` already requires (`headless_runtime=opencode`), running inside `run`. The existing `model-replay` role is the base; no new runtime.
- **Tools:** keep the existing profile (read, grep, glob, write, edit, apply_patch on; bash, task, webfetch, websearch off; no MCP/LSP/formatter/share; subagent depth 0; `external_directory` deny). For extraction, review whether `edit` and `apply_patch` are needed; the least-privilege default is `read`, `grep`, `glob`, `write` only, and the `write` tool is confined by the envelope to the single output directory. Any tool added needs a re-review. Shell stays disabled, which is what makes A's "no key readable" claim hold: with bash off, the only filesystem access is through the listed tools.
- **Invocation (never `auto`):**
  - Host side: `AIDEVOPS_WORKER_EGRESS_MODE=required`, `AIDEVOPS_WORKER_EGRESS_BACKEND=<absolute path to worker-egress-srt/backend.mjs launcher>` set for this role's process only, never in a global or user profile; `AIDEVOPS_SRT_ENVELOPE` points to an operator-owned 0600 file (not from an issue, project or model); `AIDEVOPS_MODEL_REPLAY_EXECUTION_POSTURE=enforced` (default); provider listed in `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`.
  - `sandbox-exec-helper.sh` exports `provider:NAME` policy, calls `probe`, and refuses to start on failure in `required` mode; `run` then wraps the OpenCode process tree.
  - `headless-runtime-launch.sh:470-595` already enforces the posture checks; the integration needs one **new gate**: before a run, verify the `probe` output reports `qualification: synthetic-only` or better **for the current platform**, and `ready: true`, and bind `policy_sha256`/`envelope_sha256` to the run record. Today `assertModelReplayEgressConfigured()` (`model-replay-runtime.mjs:47`) only checks the path is an executable file, and the doc says the v1 contract does not enforce the qualification fields.
  - Provider constraint to settle: `_validate_model_replay_args` rejects any model matching `anthropic|claude` and demands built-in auth plugins. Under A the client is configured with a placeholder key and a base URL for the forwarder, which these checks do not currently model. This is a launcher change, not a config toggle.
- **Platform scope:** Ubuntu x64 and NixOS x64 are qualified synthetic-only. macOS stays on `ready: false` (`macos-dns-and-ipc-qualification-pending`). NixOS arm64 and macOS x64 have no evidence. Recommend the first extraction case run on one qualified Linux host only.
- **Open gaps carried from the backend doc** (not closed here): proxy resolved-address/redirect and protocol-bypass qualification, hostile-descendant timeout per platform, provider endpoint/method probe.

## 3. Filesystem composition review (independent, design-time)

The envelope has exactly one output directory (`write`, initially empty, fresh per run), `cwd` inside it, and operator-chosen `read` roots, bounded to 64 entries. The backend refuses `/`, home, `/etc`, `/Users` but explicitly does **not** claim other read roots are safe. This is a review of what a real extraction envelope should contain and exclude. It is a **desk review of the specification and adapter notes**; it was not executed against a real extraction case, which needs the operator-supplied case.

| Class | Rule | Why |
| --- | --- | --- |
| Inputs | Read-only, copied to a dedicated per-run staging directory containing only the case's input files; never the original source tree. | A read-only bind of the original tree exposes siblings and `.git`. Copy-in also freezes content against concurrent edits. |
| Evaluator material (answers, gold labels, scoring scripts, rubrics) | Excluded from every `read` root and not co-located with inputs; verify with `rg`/`find` for known identifiers over each root. | The model must not be able to read the grader. Co-location in a parent directory is the most likely mistake. |
| Sibling cases | Excluded; one case per run with its own staging directory. | Cross-case contamination and leakage of other clients' data. |
| Executable closures | Read-only, non-writable, owned by root/operator, outside every writable root (backend enforces). Prefer a minimal closure; on NixOS name store paths, never `/nix/store`; on Homebrew the `/opt/homebrew/opt` link directory discloses installed packages and needs explicit approval. | Writable closure means code execution persistence; broad closure means ambient credentials and unrelated data. |
| Symlinks | Staging directory contains no symlinks (`find -type l` is empty); `loadEnvelope()` realpaths `read` entries but links inside a root can still point out of it. | Link inside an allowed root may expose files outside the reviewed set where the sandbox resolves it. *Verify against the sandbox's actual behaviour with a canary before release.* |
| Ambient credentials | No `~/.config`, `~/.ssh`, `~/.aidevops`, `credentials.sh`, gopass stores, cloud CLI state, `.env`, or `.git` credentials under any root; `HOME` is the output directory. | Under A the key is not in the sandbox, but other credentials in a read root defeat the boundary. |
| Output | Single owned directory; 8 MiB per-file cap is not an aggregate disk cap. | Output must be treated as untrusted data; quota is an operator decision (§4). |
| Writable overlap | No `read` root equals or contains the output directory or any ancestor of it. | A readable parent of output lets a later run's inputs include previous output. Use fresh output per invocation (backend doc). |
| `/proc`, `/sys`, `/dev` | Confirm via canary what a read tool can list; under B, `/proc/self/environ` is the key. | Direct consequence for the credential mechanism. |

**Pre-release checklist for the operator's envelope** (each yields a yes/no with command evidence): list the resolved `read` entries and confirm each is on the allowed-class list above; `rg` for evaluator and sibling identifiers across the staging directory; `find` for symlinks and for files outside the expected set; confirm output is empty and 0700; confirm no `read` root contains secrets via the repository's existing secret scanner (`secretlint`) over staging.

**Residual finding:** the Nix 64-entry bound leaves about 7 entries of margin; a nixpkgs bump can silently push the closure past it. Treat a `bounded-path-list-required` failure as the intended signal to trim, never to raise the bound.

## 4. Operator decisions (listed, not made)

1. **Model and settings:** provider, model ID, effort/variant, temperature/limits. The launcher currently forbids Anthropic/Claude IDs for replay; extraction on another model is a policy question.
2. **Credential mechanism:** A (build the forwarder), B (interim, scoped key), or neither; secret name; who revokes.
3. **Wall-time:** envelope allows 1–60 s per command today; a model run needs a different timeout class (replay cells default 3600 s with a guardian). Choose the limit and whether the sandbox `timeoutSeconds` bound must be raised, which is a backend change.
4. **Resource and cost limits:** CPU/RAM/aggregate disk are not capped by the backend. Spend cap per run and per day, provider-side where possible, and a hard-stop rule.
5. **Input release:** which cases may be sent to the provider, under what data classification, and the provider's retention terms. Nothing is released by this design.
6. **Comparison-attempt approval:** whether and how many comparison runs across models or settings are allowed, and who approves each.
7. **Platform scope:** which qualified host runs the first case; whether macOS remains on hold.
8. **Evidence required before enabling:** which of the open qualification gates (§2) must be closed first.

## 5. Proposed next steps if approved (each needs its own approval)

1. Operator answers §4 on GH#39364.
2. File implementation issues: forwarder and bridge (A) with placement decided per the open question; launcher qualification gate; optional extraction role profile with minimal tools; envelope-composition checker script.
3. Qualify with synthetic keys or an unauthenticated 401 path first; only then a scoped key on a non-sensitive case.
