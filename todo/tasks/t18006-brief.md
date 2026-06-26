# t18006: vault: add remote lock, unlock-request, and sudo plus passphrase remote unlock policy

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
- **Blocked by:** t18003, t18005
- **GitHub issue:** GH#25543
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Implement secure remote Vault control: safe remote lock, unlock request, and true remote unlock only for explicitly trusted devices using sudo authorization plus the target Vault passphrase, signed short-lived commands, and full audit.

## Why

Cloud VPS workers may need to be locked after suspected compromise or unlocked after crash/reboot. Remote unlock must never become a backdoor around the Vault passphrase.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25543; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- NEW: `.agents/scripts/vault-remote-control-helper.sh` — local/remote lock, request-unlock, unlock grant validation, policy checks.
- EDIT: `.agents/scripts/vault-message-helper.sh` — command message classes and receipt handling.
- EDIT: `.agents/scripts/approval-helper.sh` only if reusing patterns; do not reuse issue-signing keys.
- NEW: `.agents/scripts/tests/test-vault-remote-control-helper.sh` — lock command, stale/replay command, sudo gate, wrong passphrase, revoked controller.
- EDIT: `.agents/workflows/vault-fleet.md` — remote-control setup, warnings, and operator prompts.

### Implementation Steps

1. Implement remote lock as signed trusted-device command that needs no Vault passphrase but requires sender authorization to prevent nuisance/DoS.
2. Implement unlock-request as safer default: target asks user/operator to unlock locally or approve a grant.
3. Implement true remote unlock disabled by default and enabled per target device only.
4. Require `sudo aidevops fleet unlock <device>` on controlling machine plus hidden target Vault passphrase prompt; never accept passphrase in args/env/chat.
5. Use separate root-owned fleet-control key, not issue approval key, device identity key, audit key, or Vault data key.
6. Verify target, sender, trust policy, expiry, nonce/replay, command signature, and audit write before unlocking.
7. Support policy tiers: disabled, request-only, sudo+passphrase, sudo+passphrase+2-of-N.

### Verification

```bash
./.agents/scripts/tests/test-vault-remote-control-helper.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Remote lock works for trusted sender and is rejected for revoked/untrusted sender.
- [ ] Remote unlock cannot proceed without sudo and target passphrase.
- [ ] Replay/expired/wrong-target unlock grants are rejected.
- [ ] Audit records lock/unlock attempts without secrets.
- [ ] Docs clearly state cold boot/FileVault/OS login may still require local access before aidevops can receive commands.

## Context

### Reference pattern

Model human-only cryptographic approval separation on `.agents/reference/task-lifecycle.md` approval section and `.agents/scripts/approval-helper.sh`, but create separate fleet-control keys.

### Dependencies

- blocked-by:t18003
- blocked-by:t18005

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
