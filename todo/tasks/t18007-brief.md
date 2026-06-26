# t18007: vault: build tamper-evident access logs with peer replication and public-safe anchors

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
- **Blocked by:** t17998, t18003, t18004
- **GitHub issue:** GH#25544
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Implement Vault access/audit logs for locks, unlocks, reads, writes, sync, messages, device trust, and remote control, with append-only hash chains, device signatures, peer receipts, encrypted replicated logs, and optional public-safe hash anchors.

## Why

Attackers on a compromised VPS may delete local logs to hide access attempts. Replicated tamper-evident logs make past activity alteration detectable.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25544; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- NEW: `.agents/scripts/vault-audit-helper.sh` — append, verify, replicate, receipt, anchor, report.
- EDIT: `.agents/scripts/audit-log-helper.sh` or document why Vault audit remains separate.
- EDIT: Vault helper scripts to emit structured audit events before/after sensitive operations.
- NEW: `.agents/scripts/tests/test-vault-audit-helper.sh` — hash chain, missing sequence, tamper, peer receipt, public anchor.
- EDIT: GUI Vault Audit surface from UI child when available.

### Implementation Steps

1. Define event schema: event id, device id, sequence, prev hash, timestamp, actor, action, target collection, result, session id, reason, event hash, signature.
2. Encrypt full event payloads for trusted audit readers; keep public anchors to hashes/checkpoints only.
3. Sign with separate device audit key, not Vault data key, issue approval key, or fleet-control key.
4. Replicate events quickly to trusted peers/private repos and collect peer receipts.
5. Verify chain continuity and alert on missing sequence, broken signature, missing receipts, or replication stalls.
6. Log metadata only; never log passphrases, secret values, decrypted content, or full prompt/session text.

### Verification

```bash
./.agents/scripts/tests/test-vault-audit-helper.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Audit verify detects deletion/reorder/edit tampering.
- [ ] Peer receipt proves another trusted device observed an event checkpoint.
- [ ] Public anchor contains no decrypted metadata beyond safe hash/checkpoint data.
- [ ] Sensitive operations fail closed or prominently warn when audit cannot be written, per policy.

## Context

### Reference pattern

Model existing audit helpers under `.agents/scripts/*audit*`, but make Vault audit tamper-evident and replicated by design.

### Dependencies

- blocked-by:t17998
- blocked-by:t18003
- blocked-by:t18004

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
