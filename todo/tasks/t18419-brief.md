<!-- aidevops:brief-schema=v2 -->

# t18419: Add guarded IDrive e2 object storage integration

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `IDrive e2 S3 MCP subagent` → 0 hits — no relevant lessons
- [x] Discovery pass: 6 recent commits / 0 related merged PRs / 0 open PRs touch target surfaces; no existing IDrive integration found
- [x] File refs verified: hosting-services directory, Build+ subagent list, domain index, and t18418 target contract exist at HEAD; IDrive files are new
- [x] Tier: `tier:standard` — use the decided shared helper and fail-closed MCP boundary
- [x] Seeded draft PR decision recorded: skipped — blocked on t18418

## Origin

- **Created:** 2026-09-09
- **Session:** opencode:ses_f77f97e4affe54KJwSTn7JE3z9
- **Created by:** ai-interactive
- **Parent task:** t18417 / #31684
- **Blocked by:** native relationship to t18418 / #31685 plus `blocked-by:t18418`
- **Conversation context:** IDrive e2 is already used for Cloudron backups and remote storage. The user selected a thin rclone-backed integration instead of a new S3 CLI.

## What

Add an `idrive-e2` subagent and provider profile over t18418 for endpoint validation, storage inventory, Cloudron backup presence/freshness checks, restore/download previews, versioning/encryption/Object Lock/retention/lifecycle audits, and guarded changes. Do not register the current IDrive MCP in this phase.

## Why

IDrive's S3-compatible API is adequately covered by maintained clients. The official MCP package reviewed at v0.1.3 is young, `UNLICENSED`, has no declared source repository, uses a separate loopback Streamable HTTP service, and therefore does not fit aidevops' current on-demand stdio lifecycle safely.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Provider boundaries are resolved; implementation adapts the shared helper and established service-agent patterns.

## PR Conventions

Use the normal closing keyword for issue #31686. Reference parent #31684 without closing it.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** t18418 must land first.
- **Status:** blocked
- **Freshness evidence:** reviewed IDrive API, endpoint, and MCP package evidence on 2026-09-09
- **Verification run:** unrun — implementation blocked
- **Stale-assumption warning:** re-check the current MCP package license, repository provenance, version, and transport before changing the no-registration decision

## How (Approach)

### Progressive Context Plan

- **Read first:** t18418 brief and delivered helper contract; `.agents/services/hosting/cloudron.md` for backup ownership boundaries.
- **Load only if:** `.agents/tools/build-mcp/build-mcp.md` only when newer evidence makes MCP registration eligible.
- **Why:** keep Cloudron backup creation separate from remote-storage verification and avoid an unmanaged HTTP MCP.
- **Stop when:** endpoint validation, account aliasing, provider commands, docs, and fixture tests are known.

### Files to Modify

- `NEW: .agents/services/hosting/idrive-e2.md` — focused provider subagent and safety policy
- `EDIT: .agents/scripts/object-storage-helper.sh` — add only IDrive-specific endpoint/profile validation hooks not representable in config
- `EDIT: configs/object-storage-config.json.txt` — placeholder IDrive example without credentials or private regions/buckets
- `EDIT: .agents/scripts/tests/test-object-storage-helper.sh` — IDrive endpoint and backup-verification fixtures
- `EDIT: .agents/build-plus.md:43-47` — add a short provider subagent pointer under deployment/hosting
- `EDIT: .agents/reference/domain-index.md` — route IDrive/e2/S3/Cloudron backup-storage intent
- `EDIT: README.md only if the existing integrations index requires a provider entry`

### Complete Write Surface

- **Callers/readers:** `.agents/build-plus.md` and `.agents/reference/domain-index.md` route IDrive/e2 intent to `.agents/services/hosting/idrive-e2.md`, which calls the shared helper.
- **Writers/mutation paths:** `.agents/scripts/object-storage-helper.sh` selects the IDrive profile and delegates validated operations to rclone; the agent does not write storage directly.
- **Tests/fixtures:** `.agents/scripts/tests/test-object-storage-helper.sh` covers endpoint normalization, region mismatch, backup verification, and mutation refusal with mocks.
- **Schemas/config:** `configs/object-storage-config.json.txt` gains credential-free IDrive alias, endpoint, region, remote, and bucket placeholders.
- **Generated/deployed mirrors:** `.agents/scripts/subagent-index-helper.sh` updates the canonical generated index when required; source deployment follows existing setup behavior.
- **Migrations/backfills:** `configs/object-storage-config.json` remains opt-in and ignored; no persisted state migration exists and existing rclone remotes remain valid.
- **Cleanup/rollback paths:** `git revert` removes provider routing/profile/docs/tests without changing other providers or live storage.

### Implementation Steps

1. Model supported endpoints from the reviewed region-specific `s3.<region>.idrivee2.com` service URL contract; reject arbitrary hosts and require configured region/endpoint agreement.
2. Document Cloudron as the backup producer and the helper as readiness/inventory/restore/protection verifier.
3. Default to read-only commands. Require bucket, key, version, proposed effect, and post-change read-back for lifecycle, retention, legal hold, Object Lock, policy, or deletion work.
4. Treat presigned URLs as bearer capabilities and avoid returning them unless explicitly requested through a future guarded path.
5. Record the MCP deferral and exact reconsideration criteria: official source/provenance, usable license, pinned release, transport/lifecycle compatibility, and focused activation tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** read-only audits may run concurrently; protection or lifecycle changes serialize by exact bucket/key/version target.
- **Migration/rollback:** no account migration is performed; reverting code leaves existing IDrive and Cloudron credentials/configuration untouched.
- **Mixed-version/backward compatibility:** endpoint lists may evolve, so explicit configured official endpoints remain usable while strict host and region validation is preserved.
- **Idempotency/retry:** audits are replay-safe; Object Lock, retention, lifecycle, policy, and delete operations never auto-retry after ambiguous provider responses.
- **Partial failure/recovery:** report only observed object metadata and freshness; a listing cannot be promoted to successful Cloudron restore evidence.
- Object Lock at bucket creation and compliance retention can be irreversible; never infer or auto-apply them.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-object-storage-helper.sh
bunx markdownlint-cli2 ".agents/services/hosting/idrive-e2.md"
.agents/scripts/subagent-index-helper.sh check
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** helper fixtures prove endpoint/config and guarded-operation criteria; markdown/index checks prove provider discovery; changed-file lint covers every declared source and generated index.
- **Broad verification trigger:** Not required unless implementation changes shared MCP or setup infrastructure, which is outside this task's hard boundary.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `bash .agents/scripts/tests/test-object-storage-helper.sh`
- [ ] WIP commit created before broad gates: `wip: add IDrive e2 storage integration`
- [ ] Evidence-triggered broad verification then run: not required because MCP infrastructure is excluded

### Files Scope

- `.agents/services/hosting/idrive-e2.md`
- `.agents/scripts/object-storage-helper.sh`
- `.agents/scripts/tests/test-object-storage-helper.sh`
- `configs/object-storage-config.json.txt`
- `.agents/build-plus.md`
- `.agents/reference/domain-index.md`
- `README.md`

## Acceptance Criteria

- [ ] The IDrive agent can guide readiness, bounded inventory, backup freshness, and protection audits through the shared helper without requiring the MCP.
- [ ] Invalid/non-IDrive endpoints, region mismatches, ambiguous account aliases, and missing rclone configuration fail before network access.
- [ ] Destructive/protection-changing workflows require explicit target/version/effect confirmation and read-back; no write is the default.
- [ ] The OpenCode MCP registry and tool map remain unchanged unless fresh provenance and lifecycle evidence satisfies every documented gate.

## Context

- Primary sources supplied by the user: `https://www.idrive.com/s3-storage-e2/s3-compatible-api`, `https://www.idrive.com/s3-storage-e2/e2-endpoint-urls`, and `https://www.idrive.com/s3-storage-e2/mcp-for-ai#selfhosted-mcp-works`.
- The unrelated `nktknshn/idrive-cli` targets Apple iCloud Drive and must not be used as an IDrive e2 implementation reference.
