# t18001: vault: migrate aidevops memory, workspace, knowledge, and config data with scrub-safe rollback

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
- **Blocked by:** t17999, t18000
- **GitHub issue:** GH#25538
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Move sensitive aidevops data planes behind Vault storage with verified encrypt/decrypt migration, best-effort disk/memory scrubbing, rollback/manifest safety, and clear filesystem snapshot limitations.

## Why

Memory DBs, knowledge files, workspaces, mail/messages, and session-derived indexes may contain confidential client data. They need encrypted-at-rest storage and locked-state denial before fleet sync can safely replicate them.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25538; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- EDIT: `.agents/scripts/memory-helper.sh` and `.agents/scripts/memory/*` — gate memory DB reads/writes through Vault.
- EDIT: `.agents/scripts/memory-embeddings-helper*.sh` — prevent plaintext semantic indexes while locked.
- EDIT: `.agents/scripts/knowledge-helper.sh` and project data helpers as needed.
- NEW: `.agents/scripts/vault-migration-helper.sh` — manifest, encrypt, verify, scrub, rollback/archive workflow.
- NEW: `.agents/scripts/tests/test-vault-data-migration.sh` — interrupted migration, hash verify, plaintext cleanup, locked denial.

### Implementation Steps

1. Define collection keys for memory, embeddings, knowledge, workspace, mail/messages, config metadata, and audit.
2. Implement migration manifest with source path refs, hashes, encrypted destination refs, and verification state.
3. Stream plaintext into encryption where possible; avoid plaintext temp files.
4. After decrypt/hash verification, remove plaintext originals with best-effort scrubbing and document SSD/APFS/journal/snapshot limits.
5. Ensure locked helpers fail closed and do not recreate plaintext DBs/indexes.
6. Preserve archive/rollback path until migration is verified.

### Verification

```bash
./.agents/scripts/tests/test-vault-data-migration.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Memory recall/store fail closed while locked and succeed through Vault when unlocked.
- [ ] Migration interruption can resume or roll back without data loss.
- [ ] No plaintext FTS/semantic index remains as a synced/searchable leak.
- [ ] Docs state whole-disk encryption/FileVault is still needed for historical plaintext remnants and OS snapshots.

## Context

### Reference pattern

Model storage inventory on README memory storage lines and `.agents/reference/memory.md`; model credential boundary language on `.agents/tools/credentials/encryption-stack.md`.

### Dependencies

- blocked-by:t17999
- blocked-by:t18000

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
