# t18000: vault: protect managed AI session and history storage behind unlocked Vault profiles

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
- **Blocked by:** t17998, t17999
- **GitHub issue:** GH#25537
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Design and implement aidevops-managed runtime profiles that place AI session/history databases and transcript caches behind the Vault boundary, so supported AI apps can access them only while aidevops is running and unlocked.

## Why

Session/history data contains prompts, tool outputs, files, and confidential client context. Cloud VPS backups and local disk theft must not expose these histories when Vault is locked.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25537; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- EDIT: `.agents/scripts/runtime-registry.sh` — add vault-managed profile metadata for supported runtimes.
- EDIT: `.agents/scripts/session-miner/*` and `.agents/scripts/*session*` helpers — route managed session/history reads through Vault gates.
- EDIT: `.opencode/lib/opencode-db-path.ts` and related OpenCode GUI/session lookup adapters where supported.
- NEW: `.agents/scripts/tests/test-vault-managed-session-history.sh` — locked denial, unlocked path, unsupported-runtime warning.
- EDIT: `.agents/reference/vault.md` — limitations for unsupported app caches and provider-side logs.

### Implementation Steps

1. Inventory currently supported runtime history paths and distinguish managed vs unmanaged storage.
2. Add a managed profile mode that points supported runtime session/history paths into Vault-protected storage or through a broker path.
3. When Vault locks, prevent new reads and stop/suspend managed AI processes where necessary to avoid stale decrypted file handles.
4. On crash/reboot, ensure session/history remains encrypted and unavailable until unlock.
5. Document unsupported caches, crash reports, provider-side histories, and local OS artifacts that Vault cannot guarantee.

### Verification

```bash
./.agents/scripts/tests/test-vault-managed-session-history.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Locked Vault blocks aidevops session lookup/mining against managed encrypted histories.
- [ ] Unlocked Vault permits supported runtime reads through the broker only.
- [ ] Unsupported runtimes produce explicit limitation warnings, not false security claims.
- [ ] Tests cover OpenCode/Claude path classification without exposing real local paths.

## Context

### Reference pattern

Use `.agents/reference/memory-lookup.md` for current runtime lookup tiers and `.agents/scripts/runtime-registry.sh` for supported runtime metadata.

### Dependencies

- blocked-by:t17998
- blocked-by:t17999

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
