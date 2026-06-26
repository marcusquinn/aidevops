# t18010: vault: add security validation suite, crash drills, destructive-migration gates, and release criteria

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
- **Blocked by:** t17999, t18001, t18004, t18006, t18007, t18009
- **GitHub issue:** GH#25547
- **Conversation context:** User requested aidevops Vault encryption for confidential client data, cloud VPS safety, local/fleet unlock, secure sync/messaging, audit replication, UI guidance, and agent guidance.

## What

Create the Vault security validation and release gate suite covering wrong passphrase, crash mid-migration, locked access denial, sync replay, revoked devices, remote command abuse, audit tampering, and plaintext leakage checks.

## Why

Vault will protect confidential client data and operate on cloud VPS hosts. It needs high-confidence tests and release gates before default-enabling destructive migration or remote unlock features.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive Vault work spans CLI, GUI, agents, storage, fleet sync, and operational policy. It requires architecture decisions and trade-off analysis before implementation.

## PR Conventions

Leaf task: final implementation PR should use a closing keyword for GH#25547; PRs that only prepare follow-up work should use `For`/`Ref`.

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

- NEW: `.agents/scripts/tests/test-vault-security-suite.sh` or coordinated test runner for Vault-specific helpers.
- EDIT: `.github/workflows/code-quality.yml` or relevant CI workflows only after local tests exist and are fast.
- NEW: `.agents/reference/vault-security-review.md` — manual/external review checklist and release criteria.
- EDIT: `.agents/reference/ci-gate-policy.md` — classify required vs advisory Vault checks if needed.
- EDIT: Vault docs and GUI copy with final security-limit wording.

### Implementation Steps

1. Aggregate tests from Vault children into a fast required local/CI gate where practical.
2. Add crash drills: broker crash, app restart, reboot simulation, interrupted migration, interrupted sync, interrupted audit write.
3. Add adversarial cases: wrong passphrase, replayed remote command, revoked device, tampered audit chain, public Git ciphertext scan, stale unlock grant.
4. Add plaintext leakage checks for args/env/logs/temp files/test fixtures where deterministic.
5. Add release criteria: external crypto/security review before default-enabling remote unlock or destructive migration; feature flags for risky paths.
6. Ensure broad E2E tests remain staging/release advisory if too slow for every PR.

### Verification

```bash
./.agents/scripts/tests/test-vault-security-suite.sh
.agents/scripts/linters-local.sh

```

## Acceptance Criteria

- [ ] Security suite documents what is required before Vault default-on release.
- [ ] Fast deterministic tests run locally and in CI.
- [ ] Remote unlock remains feature-gated until policy and tests pass.
- [ ] Docs state limits honestly: unlocked malware/root access, provider-side AI logs, unsupported runtime caches, OS snapshots/swap.

## Context

### Reference pattern

Model CI gate classification on `.agents/reference/ci-gate-policy.md`; model shell test conventions on existing `.agents/scripts/tests/test-*.sh` files.

### Dependencies

- blocked-by:t17999
- blocked-by:t18001
- blocked-by:t18004
- blocked-by:t18006
- blocked-by:t18007
- blocked-by:t18009

Parent: #25533

### Security notes

- Do not request, log, echo, store, or place vault passphrases in issue comments, CLI arguments, environment variables, shell history, AI chat, or test fixtures.
- Treat Git, object storage, SimpleX, SSH/Tailscale, and any sync transport as untrusted unless the child explicitly proves otherwise.
- Keep always-loaded agent guidance short; put detailed Vault operating guidance in dedicated reference/workflow docs and point to it.
