# t18004: vault: add encrypted sync, export, import, rekey, and public-Git-safe replication

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `vault encryption fleet sync remote unlock` → current-session requirements captured; no prior conflicting implementation memory found before briefing.
- [x] Discovery pass: prework discovery ran against `TODO.md,todo/tasks,.agents,README.md,aidevops.sh,.opencode`; GitHub search returned no open duplicate Vault epic.
- [x] File refs verified: target path patterns checked with `git ls-files`; new Vault files are intentionally absent until implementation.
- [x] Tier: `tier:thinking` — novel cross-system security design, destructive migration risk, and multi-machine trust trade-offs.
- [x] Seeded draft PR decision recorded: skipped — issue-only is safer because implementation must follow security design decisions from blockers.

## Origin

- **Created:** 2026-06-26
- **Session:** opencode:Vault encryption design
- **Created by:** ai-interactive
- **Parent task:** t17996 (GH#25533) — Vault programme parent.
- **Blocked by:** t18001, t18003
- **GitHub issue:** GH#25541
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Implement E2EE replication for selected Vault collections across trusted devices and untrusted transports, including public/private Git mailboxes, encrypted export/import, old-passphrase to new-passphrase re-encryption, and crash-safe sync manifests.

## Why

Aidevops workloads may run across many machines. Availability should come from pre-synced encrypted replicas, not bypassing locked devices or exposing plaintext to Git hosts.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25541; PRs that only prepare follow-up work should use `For`/`Ref`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Security architecture and implementation sequencing must be resolved by the child issue and blockers; a seeded PR would anchor workers to unreviewed assumptions.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, duplicate search, and file discovery were performed in this session.
- **Verification run:** UNVERIFIED — planning issue only.
- **Stale-assumption warning:** Re-check parent/blocked issues, recent Vault PRs, and current helper/GUI files before editing.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/reference/vault.md` if it exists; otherwise start from the parent issue GH#25533 and blockers listed above.
- **Load only if:** implementation touches credentials, runtime history, fleet dispatch, or GUI surfaces — then load the matching existing docs named in Files to Modify.
- **Why:** Vault work is destructive/security-sensitive and must preserve progressive disclosure while enforcing deterministic gates in code.
- **Stop when:** target files, trust boundary, failure modes, and verification commands are clear enough to edit without guessing.

### Worker Quick-Start

- Confirm Vault is still unimplemented or partially implemented before editing; do not duplicate an already-merged child.
- Never ask for or accept a passphrase in chat, issue bodies, env vars, CLI args, or logs.
- Treat public/private Git sync as an untrusted transport; E2EE must protect contents even when repos are public.
- Add or update Vault agent/user guidance alongside functionality.
- Keep `.agents/AGENTS.md` changes to short pointers; move detail to reference/workflow docs.

### Files to Modify

- NEW: `.agents/scripts/vault-sync-helper.sh` — collection manifest, push/pull, import/export, rekey, transport adapter interface.
- NEW: `.agents/scripts/vault-git-transport-helper.sh` — public/private Git-safe encrypted record transport.
- EDIT: `.agents/scripts/vault-helper.sh` — wire export/import/rekey commands from setup child.
- NEW: `.agents/scripts/tests/test-vault-sync-helper.sh` — public repo ciphertext, replay, crash-safe resume, import rewrap.
- EDIT: `.agents/workflows/vault-fleet.md` — sync setup, metadata leakage, padding/batching, and transport warnings.

### Implementation Steps

1. Define append-only encrypted record format with collection, namespace, author device, content hash, version/vector, tombstone, signature, ciphertext, and optional padding.
2. Implement local export/import files that are encrypted and signed; never create plaintext bundles.
3. Support import that decrypts with original passphrase and re-encrypts to destination Vault, plus device-to-device transfer encrypted to recipient device key.
4. Make Git transport safe even if repo is public: opaque ids, encrypted payloads, signed records, no private filenames/paths in repo-visible names.
5. Rebuild search indexes locally after unlock; do not sync plaintext FTS or semantic indexes.
6. Add conflict semantics: memory append-only, knowledge versioned blobs/conflict copies, settings per-device by default.

### Verification

```bash
./.agents/scripts/tests/test-vault-sync-helper.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Encrypted sync payloads can be stored in a public repo without revealing contents.
- [ ] Sync import refuses unsigned, replayed, expired, or revoked-device records.
- [ ] Export/import can rewrap data for a new passphrase without plaintext bundles on disk.
- [ ] Docs explicitly call out metadata leakage: timing, size, device count, and activity frequency.

## Context

### Reference pattern

Model durable Git coordination concerns on `.agents/reference/cross-runner-coordination.md`; use `.agents/tools/app-stack/encrypted-collaboration.md` as optional design context if helpful.

### Dependencies

- blocked-by:t18001
- blocked-by:t18003

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
