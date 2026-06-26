# t17999: vault: build first-use passphrase test, restart verification, recovery, and archive flow

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
- **Blocked by:** t17998
- **GitHub issue:** GH#25536
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Implement the safe first-use setup flow: create passphrase, encrypt only harmless test text, require app quit/reopen/unlock verification before migrating real data, and provide lost-passphrase archive/start-fresh recovery.

## Why

Encryption is destructive if the user loses the passphrase or the unlock path is broken. aidevops must prove round-trip unlock before offering to encrypt real data.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25536; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- EDIT: `.agents/scripts/vault-helper.sh` — setup state machine, test record, lost-passphrase archive, backup/export hooks.
- NEW: `.agents/scripts/tests/test-vault-setup-flow.sh` — staged setup, restart-test enforcement, archive-and-start-fresh fixtures.
- EDIT: `.agents/workflows/vault-setup.md` — user prompts, warnings, acknowledgement copy, recovery options.
- EDIT: `README.md` — short no-passphrase-no-recovery warning.

### Implementation Steps

1. Add first-use wizard states: uninitialized → test-created → restart-required → test-verified → migration-ready.
2. Require 12+ character passphrase, confirmation, strength/advice copy, and acknowledgement that aidevops cannot recover it.
3. Encrypt a harmless test record only; block real-data migration until a fresh process successfully unlocks and reads the test.
4. Implement lost-passphrase flow: try again, archive encrypted vault intact, start fresh, import from another unlocked device, or restore encrypted backup/recovery kit.
5. Archive old encrypted data without deletion so later passphrase recovery can import it.
6. Add export/import/rekey command placeholders with safe errors until sync/import child implements them.

### Verification

```bash
./.agents/scripts/tests/test-vault-setup-flow.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Real data migration is unavailable before restart-test verification.
- [ ] Lost-passphrase archive keeps encrypted files intact and writes a recovery README without secrets.
- [ ] Fresh vault initialization after archive creates new metadata without overwriting the archive.
- [ ] Prompt copy tells users to save passphrase in a trusted password manager with backups.

## Context

### Reference pattern

Model user warning tone on password-manager vaults and existing `aidevops secret set` hidden-input guidance in `.agents/tools/credentials/gopass.md`.

### Dependencies

- blocked-by:t17998

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
