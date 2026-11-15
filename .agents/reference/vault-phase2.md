<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Vault RFC: Phase 2 and 2.5 Detail

Chapter of `reference/vault.md` (Aidevops Vault Security Architecture RFC), section 7. Content moved verbatim.

## Phase 2: Device registry and encrypted sync

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

`.agents/scripts/vault-message-helper.sh` is the first deterministic secure
device messaging layer for human messages, sync requests, audit receipts, remote
lock commands, unlock requests, and unlock-grant envelope placeholders. Each
device owns local-only signing and X25519 encryption keys plus an opaque mailbox
id. Senders encrypt each message to the recipient device encryption key, sign the
transport envelope, set expiry/sequence metadata, and stage only ciphertext under
public-Git-safe mailbox paths. Locked receivers can collect encrypted envelopes
and report counts; plaintext decrypt/cache steps require a local unlocked Vault
broker signal. Optional SimpleX delivery is an adapter path, not a trust boundary,
and fails closed when unavailable.

`.agents/scripts/vault-audit-helper.sh` is the dedicated Vault audit layer, kept
separate from the general `.agents/scripts/audit-log-helper.sh` because Vault
events have a stricter trust boundary: full event payloads are encrypted for
trusted audit readers, each record is signed with a device audit key that is
separate from data/sync/control keys, and public anchors contain only checkpoint
hashes plus sequence metadata. It supports append, verify, peer receipt, public
anchor, replicate, and report commands. Verification fails closed on missing
sequences, broken previous-hash links, edited encrypted payload hashes, invalid
record signatures checked against trusted local/peer audit keys, or peer receipts
that do not match the observed head. Vault CLI operations emit attempt/result
events through this helper; set `AIDEVOPS_VAULT_AUDIT_REQUIRE=1` when sensitive
deployments must fail closed if the audit event cannot be written.

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

## Phase 2.5: Data-plane migration and locked-state gates

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
