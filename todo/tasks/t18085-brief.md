<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18085: Evolve runtime-neutral autonomous safety contracts

## Pre-flight

- [x] Memory recall: `Codex harness reassessment` → 1 high-confidence lesson; adapt invariants, do not copy runtime-specific mechanisms
- [x] Discovery pass: no duplicate open issue or related open PR; active sandbox quality-debt issue #27006 identified and treated as a collision
- [x] File refs verified: policy, plugin, sandbox, observability, lifecycle, mailbox, and worker paths checked at `bbba43921`
- [x] Tier: `tier:thinking` — cross-runtime security architecture across more than four files
- [x] Seeded draft PR decision recorded: skipped — implementation follows after consolidated architecture and collision audit

## Origin

- **Created:** 2026-07-11
- **Session:** OpenCode interactive
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none; rebase after changes to overlapping sandbox files
- **Conversation context:** Reassess mature coding-agent harness lessons, then evolve aidevops around autonomous, safe value creation without Codex-specific or competing processes.

## What

Deliver one runtime-neutral safety and evidence layer that extends existing aidevops authorities:

1. one declarative safety-floor decision API consumed by runtime adapters;
2. commit-pinned, path-contained, explicitly hook-authorized plugin deployment;
3. enforced domain policy for recognized direct network clients using the existing tiers;
4. append-only lifecycle evidence in the existing observability database;
5. bounded world-state snapshots/deltas, causal IDs, and worker execution lineage.

Existing GitHub/TODO task state, mailbox delivery state, runtime transcripts, audit logs, and worker metrics remain authoritative for their domains. New event records are evidence and projections, not a competing orchestrator.

## Why

Current safety decisions are fragmented across runtime-specific hooks, plugin updates follow mutable branches without durable provenance, network tier checks can log denials without blocking, and worker/session evidence lacks a shared causal lineage. Consolidating these deterministic boundaries reduces drift and operator prompts while preserving model judgment and improving autonomous recovery, diagnosis, and safe value creation.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Security-sensitive cross-runtime work creates a shared pattern, coordinates shell, Python, MJS, SQLite, and setup paths, and requires compatibility migration and fail-safe behavior.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Active overlapping sandbox work required reconciliation before edits; a speculative seed would anchor implementation to stale code.
- **Status:** not-created
- **Freshness evidence:** memory, git, issue/PR, file, and architecture collision discovery completed against current `origin/main`
- **Verification run:** pre-edit and duplicate checks only; implementation checks pending
- **Stale-assumption warning:** re-check overlapping sandbox and canonical-Git changes immediately before rebase/merge

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/aidevops/architecture.md`, `.agents/reference/observability.md`, `.agents/aidevops/plugins.md` — preserve current authorities.
- **Load only if:** runtime adapter, sandbox, plugin, or worker test fails — inspect the corresponding focused helper and test fixture.
- **Why:** implementation must consolidate existing mechanisms rather than add parallel guidance or stores.
- **Stop when:** each adapter consumes the shared contract, duplicate rules are removed or explicitly classified as authorization rather than safety policy, and focused/full gates pass.

### Files to Modify

- `NEW: .agents/configs/command-policy.json` — versioned runtime-neutral deterministic safety-floor rules and self-test fixtures.
- `NEW: .agents/scripts/command-policy-helper.py` — token-aware evaluator that delegates dynamic Git checks to `canonical-git-command-guard.py`.
- `EDIT: .agents/hooks/git_safety_guard.py` and `.agents/plugins/opencode-aidevops/quality-hooks-git-safety.mjs` — thin runtime adapters.
- `EDIT: .agents/scripts/network-tier-helper.sh` and `.agents/scripts/sandbox-exec-helper.sh` — shared command-domain checks and blocking decisions.
- `EDIT: .agents/scripts/aidevops-cli/aidevops-skills-plugin-lib.sh`, `.agents/scripts/plugin-loader-helper.sh`, `.agents/scripts/setup/modules/plugins.sh` — staged commit-pinned plugin trust and path containment.
- `NEW: .agents/scripts/runtime-events.mjs` plus `EDIT: .agents/plugins/opencode-aidevops/observability.mjs` — append-only event/state schema in the existing observability DB.
- `EDIT: worker launch/lifecycle and pulse-current-state helpers` — execution IDs, causal lineage, and bounded state snapshots/deltas.
- `EDIT: existing policy/plugin/observability docs` — describe the consolidated authorities accurately without new always-loaded guidance.
- `NEW/EDIT: focused shell, Python, and MJS tests` — cross-runtime parity, provenance, fail-safe enforcement, privacy, lineage, and state reconstruction.

### Implementation Steps

1. Define a single safety-floor decision envelope (`allow`, `prompt`, `forbid`, reason, rule ID), with config fixtures validated before use. Keep caller authorization such as GUI/SimpleX approvals separate.
2. Route Claude, OpenCode, and sandbox shell-command checks through the shared evaluator; remove migrated duplicate destructive-command lists while retaining Edit/Write worktree checks.
3. Move direct-client destination and DNS-exfiltration classification into `network-tier-helper.sh`; make Tier 5 and malformed required worker policy block before execution, while reporting arbitrary interpreter/custom-binary traffic as outside command-policy containment.
4. Stage plugin add/update candidates, resolve a commit, validate manifest/member path containment, require explicit hook authorization, and atomically activate only verified content. Persist trust in the existing plugin registry.
5. Extend the existing observability SQLite schema with a versioned runtime-event envelope, correlation/causation and worker parent/root IDs, bounded redacted payloads, and snapshot/delta events.
6. Emit lifecycle and lineage evidence from existing worker paths while retaining current logs/metrics as compatibility projections. Add bounded pulse state snapshots without copying mailbox bodies, checkpoint prose, paths, or secrets.
7. Update existing docs in place and remove or correct claims that exceed actual enforcement.

### Verification

```bash
python3 .agents/scripts/command-policy-helper.py validate
bash .agents/scripts/tests/test-command-policy-helper.sh
bash .agents/scripts/tests/test-sandbox-command-policy.sh
bash .agents/scripts/tests/test-plugin-source-trust.sh
node --test .agents/plugins/opencode-aidevops/tests/*.mjs
shellcheck <changed-shell-files>
.agents/scripts/linters-local.sh
```

## Acceptance

- [ ] Claude, OpenCode, and sandbox adapters return identical shared safety-floor decisions for fixture commands.
- [ ] Dynamic canonical-Git protection remains delegated to the existing canonical guard rather than copied.
- [ ] Recognized direct clients deny Tier 5 and DNS-exfiltration targets; required worker policy cannot silently degrade or claim whole-process containment.
- [ ] Plugin add/update/setup deploy the recorded commit atomically, reject path traversal/mismatch, and never run hooks without explicit authorization.
- [ ] Runtime events use the existing observability DB and carry bounded redacted causal/lineage fields.
- [ ] State snapshots/deltas reconstruct deterministically and do not contain private paths, mailbox/checkpoint prose, issue bodies, or secrets.
- [ ] Existing logs, metrics, mailbox, task state, and audit systems remain compatible and retain their established authority.
- [ ] Focused tests, ShellCheck, plugin tests, and full local linters pass.
- [ ] PR passes review gates, merges, and ships in one aidevops patch release.

## Context and Constraints

- This work learns from public architectural patterns but must not reproduce Codex-specific terminology, APIs, workflows, or proprietary assumptions.
- Consolidate or replace deterministic mechanisms; do not layer conflicting guidance, policy engines, databases, or orchestration processes.
- Preserve intelligence-over-determinism: policies enforce safety floors and provenance, while models continue prioritization, triage, decomposition, and trade-offs.
- Network v1 covers recognized direct-client command enforcement. Arbitrary interpreter scripts and custom binaries remain outside command-level containment and require a portable proxy/container/firewall backend.
- OTEL remains an optional projection; SQLite is local evidence, not an operational task-state authority.
