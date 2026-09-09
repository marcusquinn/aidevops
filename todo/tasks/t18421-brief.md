<!-- aidevops:brief-schema=v2 -->

# t18421: Add guarded Wasabi object storage integration with beta MCP boundary

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `Wasabi object storage MCP` → 0 hits — no relevant lessons
- [x] Discovery pass: 6 recent commits / 0 related merged PRs / 0 open PRs touch target surfaces; no existing Wasabi integration found
- [x] File refs verified: hosting-services directory, Build+ list, domain index, shared MCP registry patterns, and t18418 target contract exist at HEAD; Wasabi files are new
- [x] Tier: `tier:standard` — deterministic adapter is decided and MCP eligibility has an explicit fail-closed gate
- [x] Seeded draft PR decision recorded: skipped — blocked on t18418

## Origin

- **Created:** 2026-09-09
- **Session:** opencode:ses_f77f97e4affe54KJwSTn7JE3z9
- **Created by:** ai-interactive
- **Parent task:** t18417 / #31684
- **Blocked by:** native relationship to t18418 / #31685 plus `blocked-by:t18418`
- **Conversation context:** Add deterministic Wasabi support equivalent to IDrive while acknowledging that the reviewed official MCP is a broad beta surface.

## What

Add a `wasabi` subagent and provider profile over t18418 for endpoint/account aliases, backup verification, restore/download previews, lifecycle/Object Lock/replication/IAM audits, and guarded operations. Evaluate the official beta MCP at implementation time and register it only if an official source/package, usable license, exact version pin, transport contract, and safe credential/lifecycle design are verifiable; otherwise document the deferral while shipping the complete helper path.

## Why

Wasabi is S3-compatible, so deterministic storage work should reuse rclone. Its MCP advertises more than 140 tools across S3, IAM, sub-accounts, and governance, which is valuable but materially broader than the initial backup-verification requirement and requires stronger provenance and tool-boundary evidence.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The adapter boundary and fail-closed MCP decision rule are resolved; the worker need not invent policy even if current MCP evidence remains insufficient.

## PR Conventions

Use the normal closing keyword for issue #31688. Reference parent #31684 without closing it unless this is the verified final child and all siblings are complete.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** t18418 must land first and the MCP source/package was not available from the reviewed landing page.
- **Status:** blocked
- **Freshness evidence:** official Wasabi MCP landing page reviewed 2026-09-09
- **Verification run:** source landing-page review only; implementation unrun
- **Stale-assumption warning:** beta capabilities and packaging may change; re-fetch official evidence before implementation

## How (Approach)

### Progressive Context Plan

- **Read first:** t18418 helper contract and the Wasabi source linked in this brief.
- **Load only if:** build-MCP, registry, activation, and MCP security docs after an official package/repository is positively identified.
- **Why:** ship a useful provider integration even when MCP provenance or lifecycle remains insufficient.
- **Stop when:** adapter tests pass and either a safely pinned MCP integration is proven or the agent clearly reports the evidence-based deferral.

### Files to Modify

- `NEW: .agents/services/hosting/wasabi.md` — provider subagent and MCP beta boundary
- `EDIT: .agents/scripts/object-storage-helper.sh` and its tests — Wasabi endpoint/profile and backup-verification behavior
- `EDIT: configs/object-storage-config.json.txt` — placeholder Wasabi profile
- `EDIT: .agents/build-plus.md:43-47` and `.agents/reference/domain-index.md` — provider routing
- `EDIT: README.md only if required by the integrations index`
- `CONDITIONAL: .agents/plugins/opencode-aidevops/mcp-registry.mjs`, `agent-mcp-tools.mjs`, a least-privilege launcher, and focused registry test — only when every MCP eligibility gate is proven from official sources

### Complete Write Surface

- **Callers/readers:** `.agents/build-plus.md` and `.agents/reference/domain-index.md` route Wasabi intent to `.agents/services/hosting/wasabi.md`; the agent calls the shared helper.
- **Writers/mutation paths:** `.agents/scripts/object-storage-helper.sh` delegates validated storage operations to rclone; conditional MCP writes require a separately proven scoped registry/launcher path.
- **Tests/fixtures:** object-storage fixtures cover Wasabi endpoints and operations; conditional MCP registration adds a focused registry test plus `test-mcp-activation.mjs` assertions.
- **Schemas/config:** `configs/object-storage-config.json.txt` gains a credential-free Wasabi profile; MCP registry/tool-map schemas change only if every eligibility gate passes.
- **Generated/deployed mirrors:** `.agents/scripts/subagent-index-helper.sh` updates the canonical generated index; source setup deployment preserves user config.
- **Migrations/backfills:** `mcp-registry.mjs` changes only when a prior framework-generated MCP entry can be positively identified; no provider-state migration or custom-config rewrite occurs.
- **Cleanup/rollback paths:** `git revert` removes provider docs/profile/tests; any eligible MCP registry/profile/launcher can be removed independently while helper support remains.

### Implementation Steps

1. Add explicit Wasabi S3 endpoint and region validation based on current official service URL documentation; do not accept arbitrary hosts.
2. Implement the same provider-neutral readiness, inventory, backup-freshness, restore preview, and protection-audit contract as other providers.
3. Distinguish S3 object operations from IAM/account-control operations. Default all IAM, policy, lifecycle, replication, retention, Object Lock, sub-account, and deletion changes to refusal until exact preview and confirmation are present.
4. Reassess MCP eligibility from official source/package evidence. If any gate is missing, do not register it and explain the deterministic helper fallback in the agent.
5. If eligible, expose only the minimum tool families needed initially, keep it disabled globally, use OAuth/least-privilege IAM, and add explicit activation/isolation tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** read-only helper audits may run concurrently; lifecycle, replication, IAM, retention, Object Lock, account, and delete changes serialize by exact target.
- **Migration/rollback:** no account migration occurs; rollback removes framework integration only and never changes live Wasabi policy or objects.
- **Mixed-version/backward compatibility:** the beta MCP may change schemas/transports, so helper-backed behavior remains canonical and MCP failure cannot remove it.
- **Idempotency/retry:** read-only audits are replay-safe; irreversible/costly mutations stop after ambiguous outcomes and require state verification before retry.
- **Partial failure/recovery:** preserve provider response/operation identifiers without secrets, disconnect failed MCP sessions, and read back exact remote state before success.
- A 140-tool surface does not justify broad IAM/account governance; existing IAM policy is necessary but not sufficient for safe agent intent.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-object-storage-helper.sh
bunx markdownlint-cli2 ".agents/services/hosting/wasabi.md"
.agents/scripts/subagent-index-helper.sh check
.agents/scripts/linters-local.sh --changed
# If MCP registration is eligible, also run its focused registry test and test-mcp-activation.mjs.
```

- **Surface mapping:** helper fixtures prove endpoint/config and guarded-operation behavior; markdown/index checks prove routing; conditional MCP tests must prove provenance pin, global denial, focused activation, config preservation, and disconnect before registration is accepted.
- **Broad verification trigger:** Not required for helper-only delivery; reassess if eligible MCP work alters shared registry schema or setup infrastructure.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `bash .agents/scripts/tests/test-object-storage-helper.sh`
- [ ] WIP commit created before broad gates: `wip: add Wasabi storage integration`
- [ ] Evidence-triggered broad verification then run: not required for helper-only delivery; conditional MCP uses focused registry tests

### Files Scope

- `.agents/services/hosting/wasabi.md`
- `.agents/scripts/object-storage-helper.sh`
- `.agents/scripts/tests/test-object-storage-helper.sh`
- `configs/object-storage-config.json.txt`
- `.agents/build-plus.md`
- `.agents/reference/domain-index.md`
- `README.md`
- `.agents/plugins/opencode-aidevops/mcp-registry.mjs`
- `.agents/plugins/opencode-aidevops/agent-mcp-tools.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`

## Acceptance Criteria

- [ ] Wasabi readiness, bounded inventory, backup freshness, restore preview, and protection audits work through the shared helper without MCP availability.
- [ ] Invalid endpoints, ambiguous aliases, arbitrary flags, missing rclone, and mutation attempts without exact approval fail closed.
- [ ] IAM/account governance and destructive storage tools are not exposed by default.
- [ ] MCP registration occurs only with cited official provenance, license, pin, transport, and security evidence plus global-denial/agent-isolation tests; otherwise the shipped agent clearly documents the safe deferral.

## Context

- Primary source supplied by the user: `https://wasabi.com/cloud-object-storage/mcp-for-ai`.
- Reviewed facts: official beta; hosted and self-hosted options; OAuth; more than 140 S3, IAM, and account-governance tools; existing IAM policies carry through; object bytes are claimed to bypass the MCP server.
