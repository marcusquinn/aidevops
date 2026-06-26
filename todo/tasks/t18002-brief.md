# t18002: vault: add GUI Vault sidebar, setup navigation, padlock indicators, and locked-state gates

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
- **Blocked by:** t17999
- **GitHub issue:** GH#25539
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Add a first-class Vault link in the aidevops app sidebar above Agents, create Vault setup/management surfaces, and render padlock indicators/tooltips wherever encrypted data appears.

## Why

Users need visible security state and guided setup. Encrypted sections must be understandable in the interface, not just in CLI docs.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25539; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- EDIT: `packages/gui-web/src/app-model.ts` — add `vault` surface before `agents`, encrypted metadata, and text copy.
- EDIT: `packages/gui-web/src/AppNavigation.tsx` — render padlock marker/tooltips and Vault navigation.
- EDIT: `packages/gui-web/src/App.tsx` and related surface components — Vault status/setup/devices/sync/messages/audit placeholders.
- EDIT: `packages/gui-shared/src/contracts.ts` and `packages/gui-api/src/app.ts` — expose Vault status/readiness metadata without secrets.
- EDIT: `packages/gui-web/src/styles.css` and GUI tests — accessible lock badges/tooltips.

### Implementation Steps

1. Add Vault sidebar item above Agents in the DevOps section.
2. Build Vault surfaces: Status, First-use Setup, Lock/Unlock, Devices, Sync, Secure Messages, Backups & Recovery, Audit Logs.
3. Introduce reusable encrypted metadata and padlock component; do not hardcode encryption state per component when the API can supply it.
4. Locked state hides previews, disables agent access buttons, and offers Unlock Vault CTA/CLI hint.
5. Tooltip copy: encrypted by aidevops Vault; contents visible only when unlocked through app or authorised vault commands.
6. Ensure accessibility: icon has text/aria label and tooltip is not the only signal.

### Verification

```bash
npm --prefix packages/gui-web test
npm --prefix packages/gui-shared test
npm --prefix packages/gui-api test
```

## Acceptance Criteria

- [ ] Vault appears in sidebar above Agents.
- [ ] Encrypted surfaces show padlock and correct tooltip in both locked and unlocked states.
- [ ] Locked Vault prevents content previews and write actions while preserving non-sensitive navigation labels.
- [ ] Component/security tests cover Vault nav order, tooltip text, and no secret values in API payloads.

## Context

### Reference pattern

Model nav structure on `packages/gui-web/src/app-model.ts` and component style on `packages/gui-web/src/AppNavigation.tsx`.

### Dependencies

- blocked-by:t17999

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
