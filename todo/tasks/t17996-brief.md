# t17996: Vault: encrypted aidevops data, fleet sync, remote control, messaging, and audit

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
- **Parent task:** None — this is the parent tracking issue.
- **Blocked by:** None
- **GitHub issue:** GH#25533
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Create the parent tracking issue for the aidevops Vault programme: encrypted local data, locked-by-default restarts, multi-device fleet sync, secure messaging, remote control, audit replication, UI guidance, and agent guidance.

## Why

aidevops needs a security-by-design boundary for confidential client data across local machines and third-party VPS hosts where disks, snapshots, backups, or unattended processes may be inspected. Third-party AI provider prompts are knowingly decrypted to providers; this programme protects local aidevops storage, fleet sync, and future local-LLM paths.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Parent task: PR bodies must use `For #25533` or `Ref #25533`, never closing keywords.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Security architecture and implementation sequencing must be resolved by the child issue and blockers; a seeded PR would anchor workers to unreviewed assumptions.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, duplicate search, and file discovery were performed in this session.
- **Verification run:** UNVERIFIED — planning issue only.
- **Stale-assumption warning:** Re-check parent/blocked issues, recent Vault PRs, and current helper/GUI files before editing.

## Phases

- Phase 1 - Vault RFC, threat model, and data classification.
- Phase 2 - Local vault broker, crypto/key architecture, and CLI gate.
- Phase 3 - First-use setup, test unlock, lost-passphrase archive, export/import, and recovery UX.
- Phase 4 - Protect AI session/history plus aidevops memory/workspace/knowledge data.
- Phase 5 - Vault UI sidebar, padlock indicators, and locked-state guidance.
- Phase 6 - Device identity, trust, sync, messaging, remote control, and replicated audit logs.
- Phase 7 - Agent guidance, task dispatch gating, local-LLM data policy, and security validation.

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

- NEW: `.agents/reference/vault.md` — threat model, architecture, and operating principles.
- NEW: `.agents/workflows/vault-setup.md` — setup, first-use test, migration, recovery, and passphrase handling.
- NEW: `.agents/workflows/vault-fleet.md` — device trust, sync, messaging, remote lock/unlock, and audit replication.
- NEW/EDIT: `.agents/vault.md` or equivalent specialist agent entry — user guidance and operational routing for Vault capabilities.
- EDIT: `aidevops.sh` and `.agents/scripts/*vault*` helpers as implementation phases create CLI commands.
- EDIT: `packages/gui-web/src/app-model.ts`, `packages/gui-web/src/AppNavigation.tsx`, `packages/gui-web/src/styles.css`, and shared/API GUI contracts as UI phases add Vault surfaces.
- EDIT: `.agents/AGENTS.md`, README, and command docs only through short progressive-disclosure pointers to the dedicated Vault references.

### Implementation Steps

1. Use this parent only for tracking and decomposition; implementation happens in child issues.
2. Keep all child issues tagged `tier:thinking` because each area needs security trade-off analysis and cross-system coordination.
3. Preserve parent/child links with GitHub sub-issues and TODO `blocked-by:` markers for ordered work.
4. Every feature child must also update the relevant Vault agent/reference/workflow guidance so aidevops can explain, operate, and safely refuse unsafe actions.
5. PRs against this parent must use `For` or `Ref` semantics; leaf child PRs use normal closing keywords.

## Acceptance Criteria

- [ ] Child issues exist for threat model, broker/crypto, setup/recovery, AI session/history protection, data migration/scrubbing, UI, device trust, sync/import/export, secure messaging, remote control, audit replication, agent guidance, local-LLM/data policy, and security validation.
- [ ] Child issues are linked as sub-issues of this parent.
- [ ] Child issues that must wait for earlier architecture decisions declare `blocked-by:` markers and native GitHub blocked-by relationships.
- [ ] All implementation children carry `auto-dispatch` and `tier:thinking`; this parent remains `parent-task` and is not directly dispatched.
- [ ] Every child includes agent/documentation acceptance criteria, not just code acceptance criteria.

## Context

### Reference pattern

Use existing aidevops helper, GUI, agent, and workflow patterns referenced in this brief. Do not invent a new framework layer where an existing helper pattern fits.

### Dependencies

No additional dependency markers beyond the Origin blocked-by field.

### Security notes

- Never expose secrets or passphrases.
- Preserve clear limits for unlocked machines, third-party AI providers, unsupported runtimes, OS swap/snapshots, and compromised hosts.
