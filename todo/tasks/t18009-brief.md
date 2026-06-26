# t18009: vault: create Vault agent guidance, user workflows, command docs, and dispatch gates

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
- **Blocked by:** t18002, t18004, t18006, t18007, t18008
- **GitHub issue:** GH#25546
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Create the Vault agent/guidance layer so aidevops sessions understand Vault capabilities, ask the right setup/management questions, refuse unsafe requests, and annotate tasks with vault/sync/provider requirements.

## Why

Security features fail if agents keep asking for passphrases in chat, bypass locked data, or omit user guidance. Agent capability guidance must ship alongside implementation.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25546; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- NEW: `.agents/vault.md` or `.agents/security/vault.md` — specialist Vault/security operations agent.
- NEW: `.agents/scripts/commands/vault.md` and command docs for `aidevops vault` / `aidevops fleet` flows.
- EDIT: `.agents/AGENTS.md` — short pointer only; keep always-loaded prompt under size ratchet.
- EDIT: `.agents/reference/agent-routing.md` and `.agents/reference/domain-index.md` — route Vault/security setup requests to the Vault agent.
- EDIT: `.agents/workflows/vault-setup.md` and `.agents/workflows/vault-fleet.md` — user-questioning flows and refusal templates.
- NEW: `.agents/scripts/tests/test-vault-agent-guidance.sh` or validator fixtures for discoverability/routing.

### Implementation Steps

1. Create a specialist Vault agent with progressive-disclosure pointers, not a long always-loaded rule dump.
2. Add setup questioning: passphrase saved, no recovery acknowledgement, local/cloud device type, sync transport, remote lock/unlock policy, audit replication, local LLM/provider policy.
3. Add management questioning: lock/unlock, archive/start fresh, import/export/rekey, device trust/revoke, sync, secure messages, audit investigation.
4. Add hard refusal guidance: never paste passphrase, never unlock from chat, never read locked data, never claim protected data was read without Vault access evidence.
5. Add task briefing guidance to include `needs_vault`, `needs_collections`, `needs_device`, `needs_remote_unlock`, and data classification.
6. Ensure all future Vault feature issues include docs/agent updates in acceptance criteria.

### Verification

```bash
./.agents/scripts/subagent_validation.py || true
.agents/scripts/linters-local.sh

```

## Acceptance Criteria

- [ ] Vault requests route to the Vault agent/specialist guidance.
- [ ] AGENTS.md adds only a short pointer and passes size ratchet.
- [ ] Command docs explain hidden prompts and safe CLI patterns.
- [ ] Dispatch/preflight guidance tells workers how to handle locked or unsynced Vault data.

## Context

### Reference pattern

Model new-agent authoring on `.agents/tools/build-agent/build-agent.md` and route table updates on `.agents/reference/agent-routing.md` / `.agents/reference/domain-index.md`.

### Dependencies

- blocked-by:t18002
- blocked-by:t18004
- blocked-by:t18006
- blocked-by:t18007
- blocked-by:t18008

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
