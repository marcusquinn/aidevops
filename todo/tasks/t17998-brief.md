# t17998: vault: implement local broker, crypto envelope, and CLI lock/unlock gate

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
- **Blocked by:** t17997
- **GitHub issue:** GH#25535
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Design and implement the first local Vault broker and CLI surface that keeps aidevops protected data locked by default, unlocks only through hidden passphrase prompts, and gates helpers/UI/agents through a single access boundary.

## Why

The broker is the enforceable security boundary. UI-only password screens or prompt-only rules are insufficient for cloud VPS, crash/restart, and agent access scenarios.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25535; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- NEW: `.agents/scripts/vault-helper.sh` — `init`, `unlock`, `lock`, `status`, `read`, `update`, `change-passphrase`, and internal broker operations.
- NEW: `.agents/scripts/vault-crypto-helper.*` or equivalent implementation module — KDF, key wrapping, AEAD helpers, metadata schema.
- NEW: `.agents/scripts/tests/test-vault-helper.sh` — wrong passphrase, locked-state denial, metadata parse, and CLI prompt-safety tests.
- EDIT: `aidevops.sh` — add `aidevops vault` command group.
- EDIT: `.agents/reference/vault.md` and `.agents/workflows/vault-setup.md` — document implemented CLI and broker semantics.

### Implementation Steps

1. Choose implementation language/library with audited crypto support and explicit passphrase memory-handling trade-offs documented in the RFC.
2. Create versioned `vault.json` metadata with KDF params, salt, wrapped root key, schema version, and no plaintext passphrase/key material.
3. Use hidden TTY prompts only; refuse passphrases supplied as CLI args, env vars, stdin from non-TTY, issue bodies, or chat-derived content.
4. Expose deterministic locked-state errors for helpers and agents.
5. Add lock-on-process-exit/crash/restart behaviour: no persisted unlock tokens by default.
6. Add audit event hooks for init/unlock/lock/status failures, but avoid logging secrets or decrypted content.

### Verification

```bash
./.agents/scripts/tests/test-vault-helper.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] `aidevops vault status` distinguishes uninitialized, locked, unlocked, and corrupted metadata states.
- [ ] `aidevops vault unlock` fails safely on wrong passphrase and never prints secrets.
- [ ] Protected read/update commands fail closed while locked.
- [ ] Tests cover wrong passphrase, missing metadata, damaged metadata, and hidden-prompt-only behaviour.

## Context

### Reference pattern

Model CLI grouping on `aidevops secret` and `.agents/scripts/secret-helper.sh`, but do not reuse gopass as the Vault data encryption boundary.

### Dependencies

- blocked-by:t17997

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
