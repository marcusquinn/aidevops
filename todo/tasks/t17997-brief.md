# t17997: vault: define threat model, data classification, and security architecture RFC

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
- **Blocked by:** None
- **GitHub issue:** GH#25534
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Create the Vault RFC that defines aidevops protected data classes, supported threat environments, trust boundaries, cryptographic design constraints, and phased architecture for local machines, third-party VPS hosts, public/private Git transports, third-party AI providers, and future local LLM use.

## Why

All later Vault implementation work is destructive or security-sensitive. Workers need one canonical decision record before designing encryption, sync, remote unlock, UI, or agent behaviour.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25534; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- NEW: `.agents/reference/vault.md` — canonical threat model, data classification, crypto primitives, trust boundaries, and phased architecture.
- NEW: `.agents/workflows/vault-setup.md` — first-use setup, passphrase, recovery, migration, and safe prompts.
- NEW: `.agents/workflows/vault-fleet.md` — device trust, secure messaging, sync, remote lock/unlock, and audit replication.
- EDIT: `.agents/tools/credentials/encryption-stack.md` — link existing gopass/SOPS/gocryptfs roles to the new Vault model.
- EDIT: `README.md` — short user-facing Vault overview and explicit third-party AI provider limitation.

### Implementation Steps

1. Read existing encryption guidance in `.agents/tools/credentials/encryption-stack.md`, `.agents/tools/credentials/gopass.md`, and `.agents/tools/credentials/gocryptfs.md` before writing new guidance.
2. Define protected data classes: memory, session/history, workspace, knowledge, mail/messages, config metadata, audit logs, device registry, and sync collections.
3. Define threat environments: cloud VPS cloned disks/snapshots/backups, compromised unattended server, local machine physical theft/remote compromise, third-party AI provider prompt decryption, and local LLM mode.
4. Recommend primitives without custom crypto: Argon2id, envelope encryption, XChaCha20-Poly1305 or AES-256-GCM through audited libraries, signed device identities, append-only hash-chained audits.
5. Define data classification labels and routing semantics: public, internal, confidential, client-confidential, secret, local-only, provider-allowed, local-LLM-only.
6. Record what Vault does not protect: malware/root access while unlocked, provider-side AI logs, unsupported runtime caches, OS crash dumps/swap/snapshots created before encryption.

### Verification

```bash
./.agents/scripts/verify-brief.sh todo/tasks/${TASK_ID}-brief.md || true
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] RFC exists with explicit protects/does-not-protect sections.
- [ ] RFC names the default-disabled status for true remote unlock and the safer remote-lock/unlock-request path.
- [ ] README links to the RFC without expanding always-loaded guidance.
- [ ] Existing encryption-stack docs clarify gopass/SOPS/gocryptfs roles vs aidevops Vault.

## Context

### Reference pattern

Model on `.agents/tools/credentials/encryption-stack.md` for progressive disclosure and `.agents/reference/cross-runner-coordination.md` for multi-machine coordination style; do not inline long rules into `.agents/AGENTS.md`.

### Dependencies

No additional dependency markers beyond the Origin blocked-by field.

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
- Include the known limitation that third-party AI provider messages are decrypted to providers; future local LLM mode reduces provider exposure but not local host compromise risk.

Parent: #25533
