<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Vault Fleet Workflow

> **Audience:** agents and maintainers designing multi-device Vault operation,
> secure messaging, encrypted sync, remote lock/unlock-request, and audit
> replication. Current status is RFC guidance; implementation must conform to
> `reference/vault.md`.

<!-- AI-CONTEXT-START -->

**TL;DR:** Treat every transport as untrusted. Sync encrypted collections and
signed manifests only. Device trust is explicit and revocable. Remote lock is
safe to prioritise; unlock-request is safer than true remote unlock. True remote
unlock remains default-disabled unless a future implementation proves a narrow,
audited, short-lived, device-bound exception.

<!-- AI-CONTEXT-END -->

## 1. Fleet Model

A Vault fleet is a set of user-approved devices that can hold encrypted Vault
collections and prove their identity with signed metadata.

Device trust states:

| State | Meaning | Allowed operations |
|---|---|---|
| `pending` | Device has requested trust but is not approved | Publish public keys and request metadata only |
| `trusted` | Full member of the user's fleet | Sync allowed collections, sign audits, approve requests |
| `limited` | Scoped access for a project, tenant, or time window | Sync only assigned collections and labels |
| `revoked` | Device must no longer receive new keys or data | Read old ciphertext only; cannot update trusted state |
| `retired` | Gracefully removed device | Historical audit identity only |

Every registry update must be signed by an already trusted device or a recovery
authority defined during setup.

## 2. Device Onboarding

Safe onboarding pattern:

1. New device creates local signing and encryption key pairs.
2. New device publishes public keys and a short human-verifiable fingerprint.
3. Existing trusted device verifies the fingerprint over an authenticated local
   channel or user-mediated check.
4. Existing trusted device signs a registry update granting `trusted` or
   `limited` state.
5. Existing trusted device rewraps only the collection keys the new device may
   access.
6. Both devices append audit events with the registry version and audit-head
   hashes they observed.

Do not approve devices solely because they can reach the same Git remote,
message channel, object bucket, SSH host, Tailscale network, or VPS account.

## 3. Sync Collections

Sync collections are encrypted bundles plus signed metadata. They may represent
memory, session/history, workspace, knowledge, mail/messages, config metadata,
audit logs, device registry snapshots, or other future Vault stores.

Each collection manifest should include:

- Collection ID and data class.
- Classification labels.
- Format version.
- Encrypted data key references per authorised device.
- Vector clock or equivalent merge metadata.
- Previous manifest hash.
- Payload hashes.
- Author device ID and signature.

Payloads should be encrypted before transport with envelope encryption and AEAD
as defined in `reference/vault.md`.

The first deterministic sync implementation is
`.agents/scripts/vault-sync-helper.sh`. It creates append-only signed records
with an opaque `record_id`, collection name, namespace hash, author device,
public signing key, sequence/vector metadata, content hash, tombstone flag,
signature, ciphertext, and optional random padding. It stages imported records in
the local encrypted sync inbox and rebuilds searchable state locally after a
trusted unlock; plaintext full-text or semantic indexes are never transport
payloads.

## 4. Transport Rules

Treat all transports as untrusted delivery mechanisms:

- **Public Git:** encrypted bundles only; no protected plaintext, private paths,
  client names, or secret identifiers.
- **Private Git:** encrypted bundles, SOPS files, public device keys, and signed
  manifests are acceptable; do not rely on private repo ACLs for confidentiality.
- **Object storage:** encrypted payloads and signed manifests only; versioned
  deletes are not erasure.
- **Secure messaging:** useful for device requests, audit-head exchange, and
  encrypted payload relay; still verify signatures and replay protection.
- **SSH/Tailscale/VPN:** authenticated transport is not a Vault trust boundary;
  payload encryption and signatures still apply.
- **Third-party VPS:** may store locked ciphertext and run limited automation;
  must not store unlock material beside ciphertext.

`.agents/scripts/vault-git-transport-helper.sh` is the public/private Git-safe
transport adapter. It writes records only under `.vault/records/<prefix>/<opaque
record id>.json`, so repo-visible names do not include private filenames,
namespaces, local paths, client names, message subjects, or collection-specific
entry identifiers. Git still leaks metadata such as commit timing, record count,
record sizes, author account, and activity frequency; use padding, batching, and
delayed pushes for sensitive workflows.

Importers must reject unsigned, tampered, expired, replayed, rolled-back, or
revoked-device records before staging payloads for local rewrap. Conflicts are
collection-specific: memory is append-only, knowledge keeps versioned blobs and
conflict copies, and settings remain per-device by default unless a future
collection policy explicitly opts into shared settings.

## 5. Remote Lock

Remote lock is the first remote-control feature to implement because it reduces
exposure without transferring unlock secrets.

A valid remote-lock request:

- Is signed by a trusted device.
- Names target device(s), collection(s), reason, and timestamp.
- Uses replay protection.
- Causes the target to close mounts/handles, stop workers that require protected
  data, clear plaintext temp files where practical, and append an audit event.
- Returns a signed acknowledgement with the target's new lock status and audit
  head.

Remote lock must be safe to process over untrusted transports because the action
is protective. Denial-of-service risk remains, so rate limits and user-visible
audit are still required.

## 6. Unlock-Request

Unlock-request is the safer remote access pattern.

Flow:

1. Remote device sends a signed request naming the collection, task, duration,
   labels, and reason.
2. Trusted approving device shows the request locally, including provider-routing
   implications.
3. User or local policy approves, narrows, or denies the request.
4. Approval rewraps only the required collection keys for the requester and a
   short duration/scope, or instructs the user to unlock locally on the target.
5. Both sides append audit events.

The passphrase and recovery material never leave the approving device or
hardware-backed flow. Agents must not ask users to paste the passphrase to make
an unlock-request succeed.

## 7. True Remote Unlock

True remote unlock means a remote request can cause a locked device to become
unlocked without a local user at that device entering unlock material. This is
default-disabled.

Any future exception must include:

- Explicit opt-in with a threat-model warning.
- Device-bound keys or hardware-backed approval.
- Short-lived grants scoped to specific collections and labels.
- Signed request/approval records and hash-chained audit events.
- Automatic relock and revocation controls.
- A local kill switch that disables remote unlock immediately.
- Tests proving passphrases/recovery material are not sent through chat,
  arguments, environment variables, logs, issue comments, or fixtures.

If these cannot be met, implement remote lock and unlock-request only.

## 8. Audit Replication

Fleet audit logs should be append-only and hash-chained per device, with
replicated summaries to detect forks and gaps.

Each audit event should include:

- Event type.
- Device ID.
- Local sequence number.
- Timestamp.
- Previous event hash.
- Event payload hash.
- Signature.
- Optional redacted human-readable summary.

Replicated audit summaries should include audit-head hashes for each device and
collection. Devices should warn when another trusted device's audit chain forks,
skips expected sequence numbers, or rolls back.

Audit payloads must not contain passphrases, recovery material, raw secrets, or
private data beyond the minimum metadata needed to understand security events.

## 9. Conflict and Revocation Handling

### Conflicts

- Use collection-specific merge rules. Memory summaries, mail caches, and config
  metadata should not share one generic merge strategy.
- Preserve conflicting encrypted payloads until a trusted device can resolve
  them.
- Do not ask a third-party AI provider to inspect conflict payloads unless the
  labels allow provider routing.

### Device revocation

After revocation:

1. Mark the device `revoked` in a signed registry update.
2. Stop rewrapping new collection keys for it.
3. Rotate or rewrap affected collection keys where practical.
4. Reject new manifests signed by the revoked device after the revocation point.
5. Preserve historical audit events for attribution.

Revocation cannot erase ciphertext or plaintext already copied to the device.

## 10. Provider-Aware Fleet Operation

Fleet sync does not make data provider-safe. Before a worker on any device sends
context to a third-party AI provider, it must evaluate Vault labels:

- `secret`, `local-only`, and `local-LLM-only` stay out of provider prompts.
- `confidential` and `client-confidential` require `provider-allowed` and task
  necessity.
- Remote VPS workers should default to locked/no-provider access for protected
  data unless explicitly unlocked and routed.
- Future local LLM workers are preferred for `local-LLM-only` data, but still
  require host trust and local cache hygiene.

## 11. Completion Evidence

Fleet tasks should produce evidence without exposing protected data:

- Signed registry version or public device fingerprint.
- Sanitised sync status showing encrypted collection counts.
- Audit-head hashes and event counts.
- Remote-lock acknowledgement status.
- Unlock-request approval/denial metadata with labels and scope, not secrets.

Public PRs/issues/comments must redact private repo names, local paths, client
names, message subjects, and private basenames.

## Related

- `reference/vault.md` -- canonical threat model, labels, primitives, and phased
  architecture.
- `workflows/vault-setup.md` -- first-use setup, migration, passphrase, recovery,
  and safe prompts.
- `reference/cross-runner-coordination.md` -- model for multi-machine state,
  auditability, and failure modes.
