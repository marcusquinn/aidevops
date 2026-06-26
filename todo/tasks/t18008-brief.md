# t18008: vault: enforce confidential data policy for provider AI, local LLM, and task dispatch routing

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
- **Blocked by:** t17997, t17998
- **GitHub issue:** GH#25545
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Add data classification and runtime routing policy so aidevops can distinguish encrypted-at-rest, decrypted locally, sent to third-party AI providers, and local-LLM-only handling for confidential client data.

## Why

Vault encryption protects local storage, but third-party AI provider prompts are decrypted to providers. aidevops needs explicit policy controls before confidential client data is used in workers.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25545; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- EDIT: `.agents/reference/vault.md` — data classification and provider/local LLM routing policy.
- EDIT: `.agents/reference/orchestration.md` and model-routing docs — task metadata for `needs_vault`, `needs_collections`, `data_classification`, `runtime_policy`.
- EDIT: `.agents/scripts/headless-runtime-helper*.sh` and dispatch preflight helpers as needed to enforce routing metadata.
- NEW: `.agents/scripts/tests/test-vault-data-policy-routing.sh` — provider-blocked, local-LLM-allowed, user-approved provider cases.
- EDIT: GUI Vault and AI Providers surfaces to show data-leaves-device warnings.

### Implementation Steps

1. Define classification labels: public, internal, confidential, client-confidential, secret, local-only, provider-allowed, local-LLM-only.
2. Add task/issue metadata conventions: `needs_vault`, `needs_collections`, `needs_device`, `needs_remote_unlock`, `data_classification`, `runtime_policy`.
3. Dispatch should avoid locked/unsynced machines and avoid third-party providers for local-only/client-confidential work unless explicitly approved.
4. Show UI/agent warnings when data will leave device for provider AI.
5. Future-proof local LLM routing without requiring a local LLM implementation in this task.
6. Ensure `secret` data never enters prompts; keep secret injection separate through existing secret tooling.

### Verification

```bash
./.agents/scripts/tests/test-vault-data-policy-routing.sh
.agents/scripts/linters-local.sh

```

## Acceptance Criteria

- [ ] Workers receive deterministic refusal when task policy forbids the selected provider/runtime.
- [ ] UI distinguishes Provider AI, Local AI, and Hybrid modes.
- [ ] Task dispatch metadata is documented and consumed by at least one preflight/gating path.
- [ ] Tests prove local-only data is not sent to provider-mode workers by default.

## Context

### Reference pattern

Model model selection constraints on `.agents/reference/orchestration.md` and existing `local-models` label usage; do not change provider credentials handling except through documented gates.

### Dependencies

- blocked-by:t17997
- blocked-by:t17998

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
