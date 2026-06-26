# t18003: vault: implement device identity, trust, revocation, and fleet unlock status model

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
- **GitHub issue:** GH#25540
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Create the device identity and trust model for multi-machine aidevops Vault fleets, including per-device keys, local unlock state, heartbeat metadata, capabilities, revocation, and policy for cloud VPS vs local machines.

## Why

Fleet sync, secure messaging, remote lock/unlock, and workload dispatch need a trusted device registry that never depends on sharing passphrases in chat or repos.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25540; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- NEW: `.agents/scripts/vault-device-helper.sh` — enroll, trust, list, revoke, heartbeat/status, capability metadata.
- EDIT: `.agents/scripts/pulse-wrapper*` and dispatch metadata only where needed to read non-secret unlocked/synced state.
- EDIT: `.agents/reference/cross-runner-coordination.md` or NEW Vault fleet doc — distinguish GitHub task coordination from Vault data replication.
- NEW: `.agents/scripts/tests/test-vault-device-helper.sh` — enroll, trust, revoke, stale heartbeat, locked-state routing.

### Implementation Steps

1. Generate per-device identity/signing/encryption keys separate from Vault data keys, audit keys, issue approval keys, and fleet-control keys.
2. Represent local unlock state as local-only volatile state; never replicate a token that unlocks another machine by default.
3. Publish non-secret heartbeat: device id, status locked/unlocked, version, capabilities, collection generation/vector, active workers, max workers.
4. Implement trust grants: sync send/receive, dispatch, remote lock, unlock request, true remote unlock, audit receipt.
5. Implement revocation workflow with key rotation tasks and peer notification.
6. Document stolen device response and VPS-specific expectations.

### Verification

```bash
./.agents/scripts/tests/test-vault-device-helper.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Device list shows trusted/untrusted/revoked state without leaking private paths or secrets.
- [ ] Revoked devices cannot decrypt new sync payloads or send accepted control messages.
- [ ] Fleet scheduler can distinguish locked, unlocked, unsynced, and capability-missing devices.
- [ ] Tests cover stale heartbeat and revoked sender rejection.

## Context

### Reference pattern

Model cross-machine coordination constraints on `.agents/reference/cross-runner-coordination.md`, but keep Vault data replication separate from GitHub issue coordination.

### Dependencies

- blocked-by:t17998

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
