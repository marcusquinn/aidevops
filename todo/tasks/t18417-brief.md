<!-- aidevops:brief-schema=v2 -->

# t18417: Add provider-neutral S3 object storage integrations for IDrive, Backblaze, and Wasabi

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `S3 object storage IDrive Backblaze Wasabi` → 0 hits — no relevant lessons
- [x] Discovery pass: 6 recent commits / 0 related merged PRs / 0 open PRs touch the proposed integration surfaces; historical Backblaze references concern desktop backup exclusions, not B2 storage
- [x] File refs verified: existing registry, agent mapping, activation tests, hosting-service parent, scripts parent, config parent, and domain index are present at HEAD; proposed provider files are new
- [x] Tier: `tier:thinking` — this is a non-dispatched roadmap parent coordinating trust-boundary work
- [x] Seeded draft PR decision recorded: skipped — implementation belongs in bounded child PRs

## Origin

- **Created:** 2026-09-09
- **Session:** opencode:ses_f77f97e4affe54KJwSTn7JE3z9
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none; this parent remains `parent-task` and is never dispatched
- **Conversation context:** The user approved a thin rclone-backed IDrive integration instead of a new S3 CLI, then requested equivalent Backblaze B2 and Wasabi support with worker-ready auto-dispatch children.

## What

Coordinate a shared, provider-neutral S3-compatible object-storage capability and guarded provider integrations for IDrive e2, Backblaze B2, and Wasabi. Child tasks own implementation; this parent records decisions, dependencies, and completion.

## Why

Cloudron backup storage and other remote-storage workflows need deterministic readiness, inventory, backup-verification, restore, and protection audits. Reimplementing S3 signing, transfer, multipart, pagination, and retries would duplicate maintained clients. A shared helper prevents three provider-specific copies while optional MCPs remain isolated action layers.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Parent coordination spans provider trust, credentials, destructive operations, and MCP provenance; each resolved implementation boundary is delegated to a standard-tier child.

## PR Conventions

PRs against this parent use `For #31684`; child PRs use the normal closing keyword for their own leaf issue. Only the final child may close this parent after all children are complete.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Separate child worktrees and PRs avoid cross-provider scope coupling.
- **Status:** not-created
- **Freshness evidence:** discovery and file verification completed against `19d1897997ee7910458cfb9e768138977ba700f1`
- **Verification run:** planning and brief validation only
- **Stale-assumption warning:** re-check provider MCP release/provenance and current registry patterns before each child implementation

## Phases

- Phase 1 - t18418 / [#31685](https://github.com/marcusquinn/aidevops/issues/31685): provider-neutral rclone-backed S3 foundation
- Phase 2 - t18419 / [#31686](https://github.com/marcusquinn/aidevops/issues/31686): guarded IDrive e2 adapter and subagent
- Phase 3 - t18420 / [#31687](https://github.com/marcusquinn/aidevops/issues/31687): guarded Backblaze B2 adapter, subagent, and official MCP
- Phase 4 - t18421 / [#31688](https://github.com/marcusquinn/aidevops/issues/31688): guarded Wasabi adapter, subagent, and beta MCP boundary

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/aidevops/architecture.md` MCP lifecycle and extension sections; `.agents/tools/build-agent/build-agent.md` MCP and placement rules.
- **Load only if:** `.agents/tools/build-mcp/build-mcp.md` when a child registers an MCP; `reference/high-stakes-operations.md` when defining destructive storage operations.
- **Why:** retain one provider-neutral operational contract while keeping provider-specific authentication and MCP surfaces isolated.
- **Stop when:** all four child issues are closed with merged PR evidence and provider docs point to the shared helper.

### Files to Modify

- `EDIT: TODO.md` — parent roadmap state only
- `NEW: todo/tasks/t18417-brief.md` — parent coordination contract
- Child briefs declare implementation files; this parent must not absorb child code.

### Complete Write Surface

- **Callers/readers:** `TODO.md`, issue #31684, and pulse/planning automation read this brief and child relationships.
- **Writers/mutation paths:** planning publication writes only `TODO.md`, this brief, issue #31684, labels, and native sub-issue/dependency relationships.
- **Tests/fixtures:** `verify-brief-helper.sh`, `git diff --check`, and changed-file lint validate planning artifacts; implementation tests belong to children.
- **Schemas/config:** `todo/tasks/t18417-brief.md` schema-v2 metadata and `TODO.md` task markers are the only schemas changed by this parent.
- **Generated/deployed mirrors:** GitHub issue `#31684` mirrors this canonical brief after issue sync; no runtime agent mirror changes here.
- **Migrations/backfills:** `issue-sync-helper.sh` replaces the initial minimal issue body; no persisted runtime data exists.
- **Cleanup/rollback paths:** `git revert` restores planning files and issue sync restores the prior body/relationships; child implementation is unaffected.

### Implementation Steps

1. Deliver t18418 first.
2. Keep t18419, t18420, and t18421 blocked by t18418 until the native dependency is verified.
3. Allow the three provider children to proceed independently after the foundation merges.
4. Close the parent only after every child has merged and provider boundaries remain consistent.

### Hazards and Compatibility

- **Concurrency/atomicity:** issue and relationship publication must use existing wrappers so concurrent pulse reconciliation does not create duplicate children.
- **Migration/rollback:** no runtime migration; revert the planning commit and issue metadata together if the roadmap is withdrawn.
- **Mixed-version/backward compatibility:** provider children must tolerate deployments where optional MCPs are absent while the shared helper remains available.
- **Idempotency/retry:** issue sync and relationship reconciliation must update the existing #31684-#31688 records, never create replacements.
- **Partial failure/recovery:** if publication stops mid-sync, keep `publication:pending`, inspect every issue, and resume reconciliation rather than dispatching partial briefs.

### Verification Before Dispatch

```bash
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18418-brief.md
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18419-brief.md
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18420-brief.md
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18421-brief.md
```

- **Surface mapping:** readiness checks prove every child brief contains bounded files, write surfaces, hazards, verification, and acceptance criteria; changed-file lint validates the parent planning files.
- **Broad verification trigger:** Not required because this parent changes planning metadata only, not shared runtime contracts.

### Files Scope

- `TODO.md`
- `todo/tasks/t18417-brief.md`

## Acceptance Criteria

- [ ] All four child issues retain their native sub-issue relationship to #31684 and provider children are blocked by #31685 until the foundation closes.
- [ ] Each provider has a focused agent and shared-helper adapter without duplicated S3 protocol implementation.
- [ ] Optional MCP failures never remove the deterministic rclone-backed path.
- [ ] No child requires real credentials or a destructive live-storage operation for CI verification.

## Context

- IDrive documents standard region-specific S3 endpoints and recommends established S3 tooling.
- `nktknshn/idrive-cli` is an unrelated iCloud Drive client and is not an implementation reference.
- Backblaze's official Labs MCP is MIT, stdio-capable, capability-aware, and includes destructive gating.
- Wasabi's official MCP is beta with more than 140 S3/IAM/account tools; source/package provenance was not exposed on the reviewed landing page.
