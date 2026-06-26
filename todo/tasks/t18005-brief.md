# t18005: vault: implement secure device messaging over Git transport with SimpleX adapter option

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
- **Blocked by:** t18003, t18004
- **GitHub issue:** GH#25542
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Add secure device-to-device messaging for aidevops machines, with encrypted messages readable only when the receiving Vault is unlocked, using Git as an untrusted durable mailbox and SimpleX as an optional lower-metadata transport.

## Why

Fleet machines need a secure way to send sync requests, unlock requests, audit receipts, worker handoffs, and operator messages without exposing contents to transport providers or public repositories.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25542; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- NEW: `.agents/scripts/vault-message-helper.sh` — send, receive, inbox, outbox, ack, prune, transport selection.
- EDIT: `.agents/scripts/simplex-bot/*` if adding optional SimpleX adapter integration.
- EDIT: `.agents/scripts/vault-git-transport-helper.sh` — mailbox layout for encrypted messages and acknowledgements.
- NEW: `.agents/scripts/tests/test-vault-message-helper.sh` — public Git mailbox, unreadable locked inbox, replay/expiry, signature validation.
- EDIT: `.agents/workflows/vault-fleet.md` — messaging operations and user guidance.

### Implementation Steps

1. Define mailbox layout with opaque device/mailbox ids, encrypted messages, signed acknowledgements, expiry, nonce/counter, and replay cache.
2. Encrypt each message to recipient device keys; sign sender identity; include no private paths or plaintext subjects in Git-visible filenames.
3. Receiving device stores encrypted inbox while locked and decrypts only after local Vault unlock.
4. Add message classes: human message, sync request, audit receipt, lock command, unlock request, unlock grant envelope placeholder.
5. Support transport plugin interface: Git durable default, SimpleX optional adapter, future SSH/object storage adapters.
6. Add batching/padding options or docs to mitigate public repo metadata leakage.

### Verification

```bash
./.agents/scripts/tests/test-vault-message-helper.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Locked receiver can list encrypted message count but not decrypt contents.
- [ ] Public Git mailbox tests show ciphertext-only payload and opaque paths.
- [ ] Revoked sender messages are rejected even if syntactically valid.
- [ ] SimpleX adapter is optional and fails closed when unavailable.

## Context

### Reference pattern

Model optional SimpleX integration on `.agents/scripts/simplex-bot/src/*` and current communications guidance under `.agents/services/communications/`.

### Dependencies

- blocked-by:t18003
- blocked-by:t18004

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
