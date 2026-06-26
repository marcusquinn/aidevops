<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Aidevops Vault Security Architecture RFC

> **Status:** RFC plus initial local CLI/broker implementation. The first shipped
> helper covers local metadata, passphrase wrapping, an in-memory broker,
> locked-state gates, managed history gates, the first verified data-plane
> migration helper, and an initial encrypted sync/export/import transport;
> GUI routing is still a future phase.

<!-- AI-CONTEXT-START -->

**TL;DR:** Aidevops Vault is the policy and architecture model for protecting
agent memory, history, workspace, knowledge, mail, metadata, audits, device
state, and sync collections. `aidevops vault` now provides the first local
encrypted metadata and in-memory broker gate; current tools such as gopass,
SOPS, and gocryptfs still cover specific storage needs while Vault defines how
protected data is classified, routed, encrypted, synced, audited, and withheld
from third-party AI providers.

**Hard limits:** Vault does not protect data from malware/root access while
unlocked, provider-side AI logs after data is sent to a third-party model,
unsupported runtime caches, unmanaged app crash reports, terminal scrollback,
or OS crash dumps/swap/snapshots created before encryption. Future local LLM
mode reduces provider exposure but does not reduce local host compromise risk.

<!-- AI-CONTEXT-END -->

## 1. Goals

Vault exists to give every later encryption, sync, remote unlock, UI, and agent
behaviour change one decision record.

It must:

- Classify aidevops protected data consistently across local machines, third-
  party VPS hosts, public/private Git transports, object storage, secure
  messaging, third-party AI providers, and future local LLM runtimes.
- Protect sensitive data at rest on machines and untrusted transports.
- Minimise plaintext lifetime and make unlocked state visible and auditable.
- Preserve agent usefulness without silently sending restricted data to
  providers that are not allowed to see it.
- Support multi-device operation without trusting transport providers.
- Prefer audited primitives and maintained libraries over custom cryptography.

Vault must not:

- Invent new cryptographic algorithms or unaudited protocols.
- Treat Git, object storage, SimpleX-style messaging, SSH, Tailscale, public
  GitHub, private GitHub, or VPS disks as trusted merely because they are
  authenticated.
- Ask agents or users to paste passphrases, recovery keys, or raw secrets into
  AI chat, command arguments, environment variables, logs, issue comments, test
  fixtures, or shell history.

## 2. Protected Data Classes

| Class | Examples | Default label | Default storage intent |
|---|---|---|---|
| Memory | Cross-session lessons, user preferences, task history | `confidential` | Encrypted local store; redacted excerpts only when provider-allowed |
| Session/history | Chat transcripts, tool outputs, runtime state, compacted checkpoints | `confidential` | Encrypted at rest; short retention; provider routing checks before reuse |
| Workspace | Draft files, generated reports, temporary data, cloned task context | `internal` or `confidential` | Per-project encrypted workspace for sensitive jobs |
| Knowledge | Indexed docs, embeddings, search cache, project notes | `internal` | Encrypted when private or client-derived; public docs may be public |
| Mail/messages | Email, chat, support tickets, outreach drafts, group messages | `client-confidential` when external-party specific | Encrypted mail/message cache; explicit provider routing |
| Config metadata | Repo registry, runner identity, model preferences, enabled features | `internal` | Local config store; avoid secret values; encrypt when correlated with clients |
| Audit logs | Security operations, unlock/lock events, sync decisions, routing denials | `confidential` | Append-only hash-chained log; replicated encrypted summaries |
| Device registry | Device public keys, trust state, revocation, last-seen audit heads | `confidential` | Signed registry; encrypted backup; public keys may sync over untrusted media |
| Sync collections | Encrypted bundles, vector clocks, collection manifests, tombstones | `confidential` | End-to-end encrypted before Git/object/message transport |

### 2.1 Managed runtime session/history profiles

`.agents/scripts/runtime-registry.sh` records whether each runtime's local
session/history store is `managed`, `unmanaged`, `external`, or `none` for Vault
purposes. The first managed profiles are OpenCode and Claude Code. When
`AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY=1` is set, aidevops session/history
readers must call `.agents/scripts/vault-managed-session-history-helper.sh
require-read <runtime>` before opening local history. Locked Vault state fails
closed with `VAULT_LOCKED`; unsupported runtimes fail with
`VAULT_UNSUPPORTED_RUNTIME` so tools warn instead of implying protection.

The managed path defaults to
`~/.aidevops/.agent-workspace/vault/managed-session-history/<runtime>/...` and
can be relocated with `AIDEVOPS_VAULT_MANAGED_HISTORY_ROOT`. Runtime launchers
are responsible for pointing supported apps at the managed path only after a
local Vault unlock. Current gates prevent aidevops mining/lookup reads while
locked; they do not migrate existing plaintext app stores automatically.

Data derived from a protected class inherits the stricter label unless a human-
reviewed transformation explicitly declassifies it. Summaries, embeddings,
filenames, audit metadata, and issue titles can leak sensitive facts and are not
automatically safe.

## 3. Classification Labels and Routing Semantics

Vault labels are additive. The strictest applicable label controls storage,
sync, and model routing.

| Label | Meaning | Storage/sync rule | Provider rule |
|---|---|---|---|
| `public` | Intended for public disclosure | May be stored and synced in plaintext | May be sent to providers |
| `internal` | Aidevops operational data not intended for publication | Encrypt at rest when practical; avoid public transports in plaintext | Provider-allowed only when task-relevant |
| `confidential` | Sensitive user/project data | Encrypt at rest and in transit; redact logs | Send only if `provider-allowed` also applies |
| `client-confidential` | Data tied to a client, customer, private repo, or third party | Encrypt and isolate by tenant/context | Do not send unless the provider and task are approved for that client/context |
| `secret` | Credentials, tokens, passphrases, private keys, recovery material | Store only in secret manager or hardware-backed key storage | Never send to AI providers or logs |
| `local-only` | Must remain on the current device | No sync except encrypted backup explicitly approved for this class | Never send to remote providers |
| `provider-allowed` | Approved to include in third-party model prompts/tool context | May be sent according to provider policy and task need | Allowed, but still minimise and redact |
| `local-LLM-only` | Model processing allowed only on a local runtime | Sync only as encrypted data; decrypt on trusted local host | Route only to local model workers |

Routing decisions should evaluate labels before context loading. If a task needs
restricted data, the agent should prefer local deterministic tools, local LLM
mode where available, or a decision-ready prompt that asks the user to run a
local command rather than exposing the data.

### Task metadata and dispatch gates

Worker-dispatchable tasks that may touch protected data should include explicit
metadata near the brief/guidance section:

| Key | Values | Dispatch meaning |
|---|---|---|
| `needs_vault` | `true`, `unlocked`, `locked-ok` | Whether plaintext Vault reads are expected. `unlocked` is a future fleet/device preflight requirement. |
| `needs_collections` | collection names | Protected stores required for the task; names are routing hints, not secrets. |
| `needs_device` | device class or identifier reference | Route to a machine that owns or can unlock the required collection. |
| `needs_remote_unlock` | `false`, `request-only`, `required` | `required` is a policy exception; default is no true remote unlock. |
| `data_classification` | labels from this section | Strictest labels controlling prompt/provider eligibility. |
| `runtime_policy` | `provider-ai`, `provider-ai-approved`, `local-ai`, `local-LLM-only`, `hybrid` | Runtime allowed to process the decrypted context. |

`.agents/scripts/vault-data-policy-helper.sh` is the first deterministic gate.
`headless-runtime-helper.sh run` calls it after model selection and before the
canary/runtime launch. It fails closed with `VAULT_POLICY_DENIED` when a remote
provider is selected for `local-only`/`local-LLM-only` data, when
`confidential`/`client-confidential` lacks `provider-allowed` or an explicit
provider approval environment gate, or when any task marks prompt context as
`secret`.

## 4. Threat Environments

### 4.1 Third-party VPS cloned disks, snapshots, and backups

Assume the provider or attacker can copy powered-off disks, stale snapshots,
volume backups, object-store data, and hypervisor-level images. Vault protects
locked data with encryption at rest and treats provider storage as untrusted.

Required properties:

- Key material required to decrypt protected data is not stored beside the
  ciphertext on the VPS.
- Snapshot-safe setup writes ciphertext before sync/backup and avoids leaving
  plaintext staging files.
- Recovery material is never placed in VPS environment variables, shell history,
  user-data scripts, cloud-init logs, or issue comments.

### 4.2 Compromised unattended server

Assume an unattended machine may be remotely compromised while Vault is locked
or unlocked.

- Locked state should deny plaintext access without local unlock material.
- Unlocked state is high risk: malware/root can read files, process memory,
  sockets, model prompts, and mounted filesystems.
- Remote operation should prefer lock, revoke, rotate, and unlock-request flows.
  True remote unlock is default-disabled because it risks turning any remote
  channel compromise into data compromise.

### 4.3 Local machine physical theft or remote compromise

Assume laptops/desktops may be stolen, imaged, or infected.

- Full-disk encryption remains mandatory baseline; Vault protects application-
  layer stores when the OS account is offline or locked.
- Passphrases must be memory-hard and entered through local secure prompts.
- Recovery must be possible without training users to store passphrases in chat,
  docs, screenshots, or plaintext notes.
- While unlocked, local malware/root access defeats Vault confidentiality.

### 4.4 Public/private Git transports and object storage

Assume all Git remotes and object stores are untrusted transport, regardless of
access controls.

- Public Git must never receive plaintext protected data.
- Private Git may carry encrypted Vault bundles, SOPS-encrypted structured
  config, public device keys, and signed metadata, but must not be treated as a
  trust boundary.
- Commit history is durable; never commit plaintext data expecting later removal
  to erase exposure.

### 4.5 Third-party AI providers

Assume any prompt, completion, tool result, system context, screenshot, or file
attachment sent to a third-party provider is decrypted to that provider for the
duration and handling defined by the provider relationship.

Vault can reduce what is sent; it cannot encrypt data while still asking a
remote model to reason over plaintext. Provider routing must therefore be
explicit:

- `secret`, `local-only`, and `local-LLM-only` data are not sent to remote
  providers.
- `confidential` and `client-confidential` data require `provider-allowed` plus
  task necessity.
- Redaction and summarisation are preferred when they preserve task quality.
- Provider-side AI logs, abuse-monitoring copies, operator access, retention, and
  model-training policy are outside Vault's technical control.

### 4.6 Future local LLM mode

Local LLM mode reduces third-party provider exposure by keeping prompts and
outputs on a trusted local machine. It does not solve:

- Local malware/root access.
- Plaintext runtime caches, model server logs, swap, crash dumps, screenshots, or
  terminal scrollback.
- Model quality failures, prompt injection, or unsafe tool use.

Local LLM mode is a routing target, not a universal declassification mechanism.

## 5. Trust Boundaries

| Boundary | Trusted for | Not trusted for |
|---|---|---|
| User with passphrase/recovery material | Authorising unlock, recovery, device trust | Keeping secrets safe after pasting into AI chat or shell history |
| Local OS account | Running helpers and enforcing file permissions | Protection against root, malware, crash dumps, swap, screenshots |
| Hardware/OS keychain | Wrapping local keys when available | Cross-device recovery by itself |
| gopass/SOPS/gocryptfs | Current storage primitives for specific scopes | Global policy, device trust, provider routing, fleet sync |
| Git/object/message transports | Delivery, versioning, conflict visibility | Confidentiality, integrity without signatures, deletion guarantees |
| Third-party AI provider | Reasoning over allowed plaintext | Keeping disallowed protected data private from provider systems |
| Local LLM runtime | Provider-avoiding inference | Host compromise resistance or guaranteed output correctness |
| Remote VPS runner | Automation while locked/unlocked according to policy | Storing keys beside ciphertext or silently unlocking sensitive data |

## 6. Cryptographic Design Constraints

Vault implementations must use maintained, audited libraries and conservative
protocols:

- **Passphrase KDF:** Argon2id with interactive parameters calibrated per device;
  store parameters with the encrypted header. Use a migration path for parameter
  increases.
- **Envelope encryption:** Generate random data-encryption keys per collection or
  object group; wrap them with user/device key-encryption keys.
- **AEAD:** Prefer XChaCha20-Poly1305 for nonce-misuse resistance and platform
  portability, or AES-256-GCM through audited libraries where hardware support
  and nonce discipline are strong.
- **Device identities:** Each trusted device has a signing key and an encryption
  key. Registry updates, trust changes, sync manifests, lock/unlock requests,
  and audit-head claims are signed.
- **Audit integrity:** Security-relevant events append to a hash chain. Replicated
  audit summaries include previous hash, event hash, device signature, and
  monotonic local sequence number.
- **Randomness:** Use OS CSPRNG only. Never derive nonces from timestamps alone.
- **No custom crypto:** Do not design new ciphers, KDFs, ad-hoc MACs, or hidden
  transport encryption. Compose standard primitives using reviewed patterns.
- **Key rotation:** Support rewrapping collection keys for device revocation and
  KDF upgrades without rewriting every payload when practical.

## 7. Phased Architecture

### Initial implementation: local CLI/broker gate

The local broker phase is implemented by `.agents/scripts/vault-helper.sh` and
`.agents/scripts/vault-crypto-helper.py`, exposed as `aidevops vault`:

- `init` creates `vault.json` metadata under `~/.config/aidevops/vault/` (or
  `AIDEVOPS_VAULT_DIR`) with schema version, KDF parameters, salt, wrapped root
  key, and no plaintext passphrase or root-key material.
- `unlock` reads the passphrase only from a hidden local TTY prompt, unwraps the
  root key, and starts a Unix-domain socket broker that keeps the root key in
  process memory only.
- `lock` stops the broker; process exit, crash, restart, or missing runtime
  socket returns the system to locked state because no unlock token is persisted.
- `status` returns `uninitialized`, `locked`, `unlocked`, or `corrupted`.
- `read` and `update` fail closed with `VAULT_LOCKED` unless the broker is
  currently unlocked. `update` reads protected payload data from stdin, but
  passphrases are never accepted from stdin, arguments, environment variables,
  issue bodies, chat, logs, or fixtures.

Crypto trade-off: the initial helper uses Python `cryptography` with scrypt and
AES-256-GCM because those audited primitives are available in the supported
runtime today. The metadata records `kdf.name` and parameters so a later
Argon2id migration can rewrap the root key without changing callers.

### Phase 0: RFC and labels

- Document protected data classes, labels, threat environments, and routing
  semantics in this RFC.
- Add workflow docs for first-use setup and fleet operation.
- Keep always-loaded guidance short; point here instead of expanding
  `.agents/AGENTS.md`.

### Phase 1: Local encrypted stores

- Inventory memory, session/history, workspace, knowledge, mail/message, config,
  and audit storage paths.
- Map each path to a label and retention policy.
- Use existing primitives where they fit: gopass for secrets, SOPS for encrypted
  structured config in Git, and gocryptfs for directory-at-rest protection.
- Add explicit lock/unlock status and safe local prompts. Do not accept
  passphrases in AI context.

### Phase 2: Device registry and encrypted sync

- Create a signed device registry with trust states: `pending`, `trusted`,
  `limited`, `revoked`, and `retired`.
- Sync only encrypted collections and signed manifests over untrusted transports.
- Include vector clocks or comparable conflict metadata for collection merges.
- Replicate hash-chained audit summaries so devices can detect missing or forked
  history.

`.agents/scripts/vault-device-helper.sh` is the first deterministic device/fleet
model. It records per-device public identity metadata, explicit trust grants,
local-only unlock state, non-secret heartbeat files, and revocation rotation
tasks. It does not store passphrases, root keys, data-encryption keys, remote
unlock tokens, private paths, or plaintext collection contents. Private device
keys remain local-only for this phase; future sync layers must sign registry and
heartbeat payloads before accepting them over untrusted transports.

Supported trust grants are `sync-send`, `sync-receive`, `dispatch`,
`remote-lock`, `unlock-request`, `true-remote-unlock`, and `audit-receipt`.
`true-remote-unlock` is never granted by default; remote lock and unlock-request
flows remain the safe default. `can-dispatch --needs-unlocked` lets schedulers
distinguish locked, unlocked, unsynced, stale-heartbeat, capability-missing, and
capacity-full devices without reading protected Vault contents.

`.agents/scripts/vault-sync-helper.sh` and
`.agents/scripts/vault-git-transport-helper.sh` are the first deterministic sync
transport layer. Sync records are signed, append-only, encrypted before transport,
and addressed by opaque random ids. Public Git-safe paths expose only the record
id prefix and encrypted JSON record; private namespaces, local paths, client
names, entry identifiers, plaintext payloads, and search indexes must not appear
in repo-visible names or files. Imports fail closed on bad signatures, replay,
rollback, expiry, or revoked author devices, then stage encrypted payloads for a
local trusted-device rewrap/reindex pass.

`.agents/scripts/vault-audit-helper.sh` is the dedicated Vault audit layer, kept
separate from the general `.agents/scripts/audit-log-helper.sh` because Vault
events have a stricter trust boundary: full event payloads are encrypted for
trusted audit readers, each record is signed with a device audit key that is
separate from data/sync/control keys, and public anchors contain only checkpoint
hashes plus sequence metadata. It supports append, verify, peer receipt, public
anchor, replicate, and report commands. Verification fails closed on missing
sequences, broken previous-hash links, edited encrypted payload hashes, invalid
record signatures, or peer receipts that do not match the observed head. Vault
CLI operations emit attempt/result events through this helper; set
`AIDEVOPS_VAULT_AUDIT_REQUIRE=1` when sensitive deployments must fail closed if
the audit event cannot be written.

Revocation marks the device `revoked`, removes grants, writes a peer-visible
registry update, and appends a local rotation task instructing follow-up workers
to rewrap collection keys and notify peers. A stolen-device response should:

1. Revoke the device immediately.
2. Lock or shut down any reachable runner on that host.
3. Rotate affected collection keys before accepting new sync payloads.
4. Treat old Git/object/message transports as compromised ciphertext archives.
5. Review audit summaries for missing or forked history.

VPS devices are expected to run locked unless a task explicitly requires unlocked
protected data and the device has a fresh heartbeat plus matching grants. Never
place recovery material in cloud-init, environment variables, issue comments,
logs, or shell history.

### Phase 2.5: Data-plane migration and locked-state gates

`.agents/scripts/vault-storage-lib.sh` is the shared fail-closed gate for helpers
that read or write protected local data. Memory recall/store, semantic memory
embeddings, and knowledge add/list/search call it before opening plaintext stores.
When Vault metadata exists, or `AIDEVOPS_VAULT_REQUIRE=1` is set for tests or
managed deployments, a locked or unavailable broker returns `VAULT_LOCKED` and
must not create fresh plaintext databases or generated semantic indexes.

`.agents/scripts/vault-migration-helper.sh` migrates current aidevops data-plane
files into Vault entries with a TSV manifest containing collection, source path,
SHA-256 hash, encrypted entry reference, and verification state. It streams each
source file to `vault update <entry>`, reads the entry back with `vault read`,
compares hashes, and only then removes the plaintext original with best-effort
scrubbing. Rollback restores files from verified Vault entries instead of keeping
a plaintext rollback copy.

Initial collection keys are `memory`, `embeddings`, `knowledge`, `workspace`,
`mail-messages`, `config-metadata`, and `audit`. Public/private Git, object
storage, and sync transports may carry only encrypted entries and non-secret
manifests. The helper cannot erase historical plaintext from SSD remapping,
APFS/journal metadata, filesystem snapshots, backups, swap, crash dumps, terminal
scrollback, or committed Git history; full-disk encryption/FileVault remains a
baseline requirement for historical remnants.

### Phase 3: Remote lock and unlock-request

- Implement remote lock first: a trusted device can request that another device
  unmount stores, stop workers that require protected data, and record an audit
  event.
- Implement unlock-request second: a remote device can ask for approval, but the
  passphrase/recovery material stays local to the approving device or hardware
  authenticator.
- Keep true remote unlock default-disabled. Enabling it requires an explicit
  threat-model exception, strong device-bound encryption, short-lived grants,
  clear audit events, and a local kill switch.

### Phase 4: Provider-aware routing and local LLM mode

- Gate context loading and tool-output reuse on Vault labels.
- Route `local-LLM-only` data to local model workers when available.
- For remote providers, send the minimum provider-allowed context needed for the
  task and record redaction/routing decisions in audit metadata.
- Enforce task metadata with `vault-data-policy-helper.sh` before launching
  headless workers so provider-denied jobs stop before prompt delivery.

## 8. Protects

Vault is intended to protect against:

- Offline disk theft, copied home directories, cloned VPS disks, stale snapshots,
  and object-store/Git transport disclosure when data is locked and encrypted.
- Accidental plaintext commits or sync uploads when routing and storage policies
  are enforced.
- Cross-device tampering with sync manifests, device trust state, and audit
  history when signatures and hash chains are verified.
- Provider overexposure by denying or redacting disallowed context before it is
  sent to third-party AI systems.
- Ambiguous future implementation by defining accepted primitives, labels, and
  trust boundaries up front.

## 9. Does Not Protect

Vault does not protect against:

- Malware, root access, malicious browser extensions, or debugger access on a
  host while protected data is unlocked.
- Third-party AI provider logs, retention, operator access, abuse monitoring, or
  training policy after plaintext has been sent to that provider.
- Runtime caches not yet integrated with Vault, unsupported tool logs, terminal
  scrollback, screenshots, crash dumps, swap, hibernation files, or backups made
  before encryption.
- Weak passphrases, passphrases pasted into chat, recovery material committed to
  Git, or secrets passed through command arguments/environment variables.
- Compromised dependencies or malicious code that runs inside the trusted local
  process while data is unlocked.
- Deletion guarantees from Git history, object storage versioning, provider
  backups, or synced replicas.

## 10. Relationship to Current Credential Tools

Current credential tooling remains valid and should be composed under the Vault
model:

- `tools/credentials/gopass.md`: individual secrets such as API keys, tokens, and
  passwords. Values never enter AI context.
- `tools/credentials/sops.md`: structured secret-bearing files that must be
  committed to Git in encrypted form.
- `tools/credentials/gocryptfs.md`: directory-level encryption at rest for
  sensitive local workspaces and intermediate files.
- `tools/credentials/encryption-stack.md`: decision guide for choosing the
  smallest current tool. Vault is the framework-level classification, routing,
  trust, sync, and audit architecture.

## 11. Operational Rules for Future Work

- Every Vault implementation issue must name the data classes it touches, labels
  it enforces, trust boundary crossed, and verification command.
- Security-sensitive Vault work must include a negative test or checklist proving
  passphrases/secrets are not accepted through chat, arguments, environment
  variables, logs, issue comments, or fixtures.
- New always-loaded guidance should be a short pointer to this RFC or the Vault
  workflows, not a full rule expansion.
- Any proposal for true remote unlock must start default-disabled and include a
  safer remote-lock/unlock-request alternative.

## Related

- `workflows/vault-setup.md` -- first-use setup, passphrase, recovery, migration,
  and safe prompts.
- `workflows/vault-fleet.md` -- device trust, sync, secure messaging, remote
  lock/unlock-request, and audit replication.
- `tools/credentials/encryption-stack.md` -- current gopass/SOPS/gocryptfs
  decision guide.
