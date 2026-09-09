<!-- aidevops:brief-schema=v2 -->

# t18420: Add guarded Backblaze B2 object storage and official MCP integration

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `Backblaze B2 object storage MCP` → 0 hits — no relevant lessons
- [x] Discovery pass: 6 recent commits / 0 related merged PRs / 0 open PRs touch target surfaces; historical Backblaze work concerns desktop backup exclusions
- [x] File refs verified: registry, agent MCP mapping, activation profile builder, Blender/QuickFile registry tests, hosting-services directory, Build+ list, and domain index exist at HEAD
- [x] Tier: `tier:standard` — official stdio MCP and existing bounded activation pattern provide a credible implementation path
- [x] Seeded draft PR decision recorded: skipped — blocked on t18418

## Origin

- **Created:** 2026-09-09
- **Session:** opencode:ses_f77f97e4affe54KJwSTn7JE3z9
- **Created by:** ai-interactive
- **Parent task:** t18417 / #31684
- **Blocked by:** native relationship to t18418 / #31685 plus `blocked-by:t18418`
- **Conversation context:** Add the same deterministic storage capability as IDrive, while taking advantage of Backblaze's stronger official MCP provenance and stdio lifecycle.

## What

Add a `backblaze-b2` subagent and shared-helper provider profile, plus a pinned on-demand integration for the official MIT `backblaze-labs/b2-mcp` stdio server. Keep credentials least-privilege, disable tools globally, preserve capability-aware registration, block destructive actions by default, and exclude partner/master-key operations from the aidevops baseline.

## Why

The shared helper covers deterministic backup/storage operations. Backblaze's official MCP adds B2-native control-plane features, analytics, key capability discovery, and guarded tools that generic S3 clients do not expose.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Trust and lifecycle decisions are specified; the worker applies established MCP registry, launcher, and service-agent patterns with normal compatibility validation.

## PR Conventions

Use the normal closing keyword for issue #31687. Reference parent #31684 without closing it.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** t18418 must land first and the package version/pin must be verified at implementation time.
- **Status:** blocked
- **Freshness evidence:** `backblaze-labs/b2-mcp` main branch and README reviewed 2026-09-09
- **Verification run:** source metadata only; implementation unrun
- **Stale-assumption warning:** verify the npm package version, engines, exports, integrity, and official repository release before pinning

## How (Approach)

### Progressive Context Plan

- **Read first:** t18418 helper contract; `.agents/aidevops/architecture.md:148-170`; `.agents/plugins/opencode-aidevops/mcp-registry.mjs:175-223,465-474`; `.agents/plugins/opencode-aidevops/agent-mcp-tools.mjs:10-50`.
- **Load only if:** `.agents/tools/build-mcp/build-mcp.md` for MCP security and package verification; QuickFile/Blender tests for exact activation assertions.
- **Why:** combine deterministic storage operations with a least-privilege, disabled, explicit MCP activation profile.
- **Stop when:** package pin, secret launcher, tool pattern, provider profile, and tests are exact.

### Files to Modify

- `NEW: .agents/services/hosting/backblaze-b2.md` — provider subagent covering helper and MCP usage
- `EDIT: .agents/scripts/object-storage-helper.sh` and its test — Backblaze endpoint/profile and backup-verification behavior
- `EDIT: configs/object-storage-config.json.txt` — placeholder Backblaze profile
- `NEW: .agents/scripts/backblaze-b2-mcp-launcher.sh` — pinned stdio launcher injecting only approved B2 application-key secrets
- `EDIT: .agents/plugins/opencode-aidevops/mcp-registry.mjs:194-456` — disabled local MCP with activation agent/source/model tier
- `EDIT: .agents/plugins/opencode-aidevops/agent-mcp-tools.mjs:17-50` — restrict MCP tools to `backblaze-b2`
- `NEW: .agents/plugins/opencode-aidevops/tests/test-backblaze-b2-mcp-registry.mjs` — registry, isolation, pin, and activation tests modeled on Blender/QuickFile
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs:35-75` — update explicit profile count/assertions if required
- `EDIT: .agents/build-plus.md:43-47`, `.agents/reference/domain-index.md`, and generated subagent index through the canonical helper
- `EDIT: README.md only if required by the integrations index`

### Complete Write Surface

- **Callers/readers:** `.agents/build-plus.md` and `.agents/reference/domain-index.md` route B2 intent to `.agents/services/hosting/backblaze-b2.md`; OpenCode reads the registry/tool-map entries.
- **Writers/mutation paths:** `.agents/scripts/object-storage-helper.sh` delegates storage work to rclone, while `.agents/scripts/backblaze-b2-mcp-launcher.sh` starts the pinned stdio MCP with approved application-key secrets.
- **Tests/fixtures:** object-storage fixtures cover provider behavior; `test-backblaze-b2-mcp-registry.mjs` and `test-mcp-activation.mjs` cover pinning, denial, activation, isolation, and disconnect.
- **Schemas/config:** `configs/object-storage-config.json.txt` gains a credential-free B2 profile; `mcp-registry.mjs` and `agent-mcp-tools.mjs` gain one disabled, scoped server definition.
- **Generated/deployed mirrors:** `.agents/scripts/subagent-index-helper.sh` updates the canonical generated index; setup deploys source agents/scripts and preserves user custom MCP configuration.
- **Migrations/backfills:** `mcp-registry.mjs` updates an existing framework-generated Backblaze entry only if positively identified; otherwise no migration or user-config rewrite occurs.
- **Cleanup/rollback paths:** `git revert` removes MCP registration/profile/launcher independently while shared-helper B2 support can remain operational.

### Implementation Steps

1. Verify current package metadata and source correspondence; pin an exact reviewed version rather than `latest`.
2. Add the provider profile to the shared helper with explicit B2 endpoint/region handling.
3. Create a least-privilege launcher sourcing only `B2_APPLICATION_KEY_ID` and `B2_APPLICATION_KEY`; do not request or pass `B2_MASTER_KEY_ID` or `B2_MASTER_KEY`.
4. Set destructive policy to block by default, durable-secret sink off, inline secrets off, local-file access off unless a later explicit workflow requires a bounded root.
5. Register disabled globally with an explicit activation agent and scoped tool pattern; connect only within `backblaze-b2`, then disconnect.
6. Document capability-aware tool visibility and prefer presigned byte paths for large transfers; use the helper/rclone for deterministic backup verification.

### Hazards and Compatibility

- **Concurrency/atomicity:** registry activation is session-bounded and disconnects after use; concurrent storage reads are safe while destructive operations serialize by exact target.
- **Migration/rollback:** do not rewrite custom MCP configs; registry rollback removes only the positively identified framework entry and launcher.
- **Mixed-version/backward compatibility:** detect supported Node and exact package exports before launch; helper-backed B2 operations remain available when the MCP cannot run.
- **Idempotency/retry:** connection and read-only queries may retry after clean failure; destructive/key-management operations never retry after ambiguous completion.
- **Partial failure/recovery:** disconnect on startup/tool failure, preserve diagnostic output without secrets, and verify remote state before considering any mutation successful.
- Tool prefixes include B2-native and S3 tools; verify actual OpenCode namespacing instead of guessing the glob.
- Key-management and partner/group tools remain outside the baseline because they create durable credentials or require master keys.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-object-storage-helper.sh
shellcheck .agents/scripts/backblaze-b2-mcp-launcher.sh
node --test .agents/plugins/opencode-aidevops/tests/test-backblaze-b2-mcp-registry.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs
bunx markdownlint-cli2 ".agents/services/hosting/backblaze-b2.md"
.agents/scripts/subagent-index-helper.sh check
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** object-storage fixtures prove provider behavior; launcher ShellCheck proves shell safety; registry/activation tests prove pinning, global denial, scoped activation, config preservation, and disconnect; changed-file lint covers all declared integration files.
- **Broad verification trigger:** Not required unless the implementation changes shared registry schema or setup behavior beyond one additive MCP entry.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `node --test .agents/plugins/opencode-aidevops/tests/test-backblaze-b2-mcp-registry.mjs`
- [ ] WIP commit created before broad gates: `wip: add Backblaze B2 storage and MCP integration`
- [ ] Evidence-triggered broad verification then run: not required unless shared registry schema changes

### Files Scope

- `.agents/services/hosting/backblaze-b2.md`
- `.agents/scripts/object-storage-helper.sh`
- `.agents/scripts/tests/test-object-storage-helper.sh`
- `configs/object-storage-config.json.txt`
- `.agents/scripts/backblaze-b2-mcp-launcher.sh`
- `.agents/plugins/opencode-aidevops/mcp-registry.mjs`
- `.agents/plugins/opencode-aidevops/agent-mcp-tools.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-backblaze-b2-mcp-registry.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`
- `.agents/build-plus.md`
- `.agents/reference/domain-index.md`
- `README.md`

## Acceptance Criteria

- [ ] Backblaze helper operations work without MCP and distinguish B2 cloud storage from the unrelated Backblaze desktop backup client.
- [ ] The MCP is pinned, disabled globally, available only to `backblaze-b2`, and starts through a launcher that does not expose or request master keys.
- [ ] Missing/invalid credentials, unsupported Node, unavailable package, destructive calls, durable-secret output, and unauthorized local-file access fail closed.
- [ ] Focused tests prove registry allowlisting, global denial, bounded agent registration, custom-config preservation, and disconnect behavior.

## Context

- Primary source supplied by the user: `https://github.com/backblaze-labs/b2-mcp`.
- Reviewed repository facts: official Backblaze Labs incubation, MIT license, 40 capability-aware tools, stdio default, explicit destructive policy, and maintained tests/CI.
