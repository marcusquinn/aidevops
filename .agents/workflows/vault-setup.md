<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Vault Setup Workflow

> **Audience:** agents and maintainers using or extending first-use Vault setup,
> migration, recovery, and safe prompts. The first local CLI/broker helper is
> implemented; future storage, fleet, and GUI phases must conform to
> `reference/vault.md`.

<!-- AI-CONTEXT-START -->

**TL;DR:** Vault setup is local-first. Use `aidevops vault init`, `aidevops
vault unlock`, `aidevops vault lock`, `aidevops vault status`, and `aidevops
vault setup-state` for the first local broker gate. Real data migration remains
blocked until a fresh unlock verifies the harmless setup test record. Never ask
for or accept Vault passphrases, recovery phrases, private keys, or raw secrets
in AI chat, CLI arguments, environment variables, logs, issue comments, or
fixtures. Use local interactive prompts, classify data before migration, and
keep third-party AI provider routing explicit.

<!-- AI-CONTEXT-END -->

## 1. Setup Goals

First-use setup must create a protected local baseline without training unsafe
habits. A valid setup flow:

1. Explains what Vault protects and what it does not protect.
2. Collects passphrases only through local hidden prompts or OS/hardware-backed
   key prompts.
3. Creates or imports local key material without printing it.
4. Classifies existing aidevops data before migration.
5. Records an audit event for setup, migration, and recovery operations without
   storing secret values.
6. Leaves a visible lock/unlock status and a safe recovery path.

## 2. Safe Prompt Contract

Agents must use wording like this when setup requires user-held secrets:

> Run the Vault setup helper in your own terminal. Enter the Vault passphrase
> only into the local hidden prompt. Do not paste passphrases, recovery material,
> private keys, or secret values into AI chat.

Agents must not request:

- Vault passphrases.
- Recovery phrases or recovery key shards.
- Private device keys.
- Raw API tokens, passwords, or credentials.
- Screenshots or logs that reveal the above.

Agents may request non-secret evidence:

- Whether setup completed.
- Key fingerprints or public device IDs.
- Sanitised error codes/messages that do not contain secret values.
- Lock/unlock status produced by a helper that redacts sensitive fields.

## 3. First-Use Flow

### Current CLI quick start

Run these commands only in a local terminal where the user can type into the
hidden prompt:

```bash
aidevops vault init
aidevops vault setup-state
aidevops vault status
aidevops vault unlock
aidevops vault setup-state
aidevops vault lock
```

Expected states:

- Before setup: `aidevops vault status` prints `uninitialized`.
- After setup and before unlock: status prints `locked`; setup-state prints
  `restart-required`.
- After a successful local TTY unlock in a fresh process: status prints
  `unlocked` while the broker process is alive; setup-state prints
  `migration-ready` after the harmless encrypted test record is read.
- After `aidevops vault lock`, broker exit, crash, or restart: status prints
  `locked` and protected reads/updates fail closed.
Real data writes are blocked with `VAULT_MIGRATION_BLOCKED` until setup-state is
`migration-ready`.

The initial helper writes `vault.json`, encrypted store data, and redacted audit
events under `~/.config/aidevops/vault/` unless `AIDEVOPS_VAULT_DIR` relocates
the store. Do not publish that path when it contains private machine or client
context.

Initial setup requires a 12+ character passphrase, confirmation, and the exact
local acknowledgement `I UNDERSTAND` that aidevops cannot recover a lost
passphrase. Store the passphrase in a trusted password manager with backups.

### Step 1: Explain boundaries

Before creating a Vault, the setup UI/helper should show a concise boundary
statement:

- Protects locked local stores, encrypted backups, and encrypted sync bundles.
- Does not protect against malware/root access while unlocked.
- Does not protect provider-side AI logs after data is sent to a third-party AI
  provider.
- Does not retroactively encrypt old OS snapshots, crash dumps, swap, shell
  history, or unsupported runtime caches.
- Future local LLM mode reduces third-party provider exposure but does not reduce
  local host compromise risk.

### Step 2: Inventory local data

Classify existing paths by `reference/vault.md` data classes before migration:

| Data class | Examples to inventory | Default action |
|---|---|---|
| Memory | Cross-session memory DB/files | Encrypt or migrate into encrypted store |
| Session/history | Runtime transcripts, checkpoints | Encrypt current retention set; expire stale low-value data |
| Workspace | Agent work/tmp/mail dirs | Move sensitive projects into encrypted workspace |
| Knowledge | Private indexes, embeddings, notes | Encrypt if private/client-derived; leave public indexes public only if verified |
| Mail/messages | Mailbox and message caches | Encrypt; tenant-isolate when client-specific |
| Config metadata | Repo registry and runtime preferences | Keep non-secret; encrypt when client-correlated |
| Audit logs | Security and sync events | Start append-only hash chain |
| Device registry | Local public keys and trust state | Create signed local registry |
| Sync collections | Existing synced data bundles | Re-encrypt before future transport sync |

### Step 3: Choose local unlock method

The default unlock method should combine:

- User passphrase processed through Argon2id with stored parameters.
- OS/hardware-backed key wrapping where available.
- A recovery method that can survive device loss without copying the primary
  passphrase into plaintext notes.

Do not store passphrases in environment variables, shell profile files,
credentials templates, issue bodies, PR bodies, test fixtures, or AI memory.

### Step 4: Create local Vault metadata

Initial metadata should include:

- Vault format version.
- KDF parameters.
- Device public signing/encryption keys.
- Empty or migrated collection manifests.
- Audit-chain genesis event.
- Local routing policy defaults.

Private key material must be encrypted or hardware-wrapped before persistence.

### Step 5: Migrate current tools deliberately

Current tools are still the right primitive for many scopes:

- Keep individual API keys, tokens, and passwords in gopass via
  `aidevops secret`.
- Keep structured secret config committed to Git under SOPS.
- Keep sensitive directories at rest under gocryptfs until native Vault storage
  exists.

Vault setup should record these as protected collections and routing rules; it
does not need to merge every existing tool into one physical store.

### Step 6: Verify lock/unlock status

After setup, helpers should prove:

- Locked state denies plaintext reads.
- Unlock state is visible and scoped.
- Lock closes mounts/handles and removes plaintext temp files where practical.
- Status output exposes no secret values.

## 4. Recovery Design

Recovery must be safe by default:

- Recovery material is created locally and shown only through a local secure UI
  or written to a user-chosen offline destination.
- Agents never see recovery material.
- Recovery flow rotates or rewraps affected keys after use.
- Lost-device recovery revokes the missing device before adding a replacement.
- Recovery audit events include device IDs, timestamps, and operation type, not
  secret values.

Acceptable recovery approaches include offline recovery codes, hardware-backed
keys, Shamir-style splits implemented by audited libraries, or trusted-device
approval. Avoid bespoke recovery cryptography.

The currently implemented lost-passphrase CLI flow is conservative:

```bash
aidevops vault lost-passphrase
aidevops vault lost-passphrase archive-and-start-fresh
```

The archive-and-start-fresh path moves active encrypted metadata, store, and
audit files into a private `archives/lost-passphrase-*` directory, writes a
README without secrets, clears the local broker runtime, and leaves the active
Vault uninitialized so a new setup can start. It does not decrypt or delete the
archive; future import tooling can attempt recovery if the passphrase is later
found.

## 5. Migration Checklist

For each migrated path:

1. Identify data class and labels.
2. Decide whether migration is copy-then-verify, move, or leave-in-place with
   gopass/SOPS/gocryptfs ownership.
3. Encrypt before syncing or backing up.
4. Verify plaintext source cleanup where safe and non-destructive.
5. Record an audit event.
6. Run a secret scan or equivalent hygiene check before any PR/public output.

## 6. Provider Routing During Setup

Setup may need an agent to explain errors or generate a plan. Before sending
context to a third-party AI provider:

- Strip passphrases, recovery material, private keys, token values, and raw
  secret-bearing config.
- Prefer key fingerprints, public device IDs, and sanitised helper status.
- Treat migration inventories as `confidential` unless all paths and names are
  verified public/non-sensitive.
- Use future local LLM routing for `local-LLM-only` setup diagnostics.

## 7. Completion Evidence

A setup or migration task is complete only with evidence such as:

- Sanitised helper status showing locked/unlocked state.
- Audit event count or hash-chain head, without secret values.
- File/path inventory showing expected collections, with private paths redacted
  in public comments.
- Verification command output from local helpers.

Do not publish private basenames, client names, local paths, passphrase hints, or
secret identifiers in public issues, PRs, or comments.

## Related

- `reference/vault.md` -- threat model, data classes, labels, cryptographic
  constraints, trust boundaries, and phased architecture.
- `workflows/vault-fleet.md` -- multi-device trust, sync, remote lock,
  unlock-request, and audit replication.
- `tools/credentials/encryption-stack.md` -- current credential/encryption tool
  decision guide.
