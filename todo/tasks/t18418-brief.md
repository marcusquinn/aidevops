<!-- aidevops:brief-schema=v2 -->

# t18418: Build provider-neutral rclone-backed S3 object storage foundation

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `S3 object storage helper rclone` → 0 hits — no relevant lessons
- [x] Discovery pass: 6 recent commits / 0 related merged PRs / 0 open PRs touch target surfaces; no existing object-storage helper exists
- [x] File refs verified: `.agents/scripts/`, `.agents/scripts/tests/`, `configs/`, `.gitignore:4-11`, `.agents/aidevops/architecture.md:173-179`, and `.agents/reference/high-stakes-operations.md` are present at HEAD
- [x] Tier: `tier:standard` — architecture and safety boundaries are decided; implementation adapts established helper patterns
- [x] Seeded draft PR decision recorded: skipped — no implementation was requested in this planning session

## Origin

- **Created:** 2026-09-09
- **Session:** opencode:ses_f77f97e4affe54KJwSTn7JE3z9
- **Created by:** ai-interactive
- **Parent task:** t18417 / #31684
- **Blocked by:** none; first available leaf
- **Conversation context:** Provide one deterministic operational layer for IDrive e2, Backblaze B2, and Wasabi without implementing S3 or depending on an MCP.

## What

Create a provider-neutral `object-storage-helper.sh` backed by an installed rclone binary, a safe account-alias config template, and fixture-driven tests. Expose bounded readiness, bucket listing, object listing/metadata, backup-freshness verification, protection audit, dry-run copy/download, and explicit guarded mutation interfaces that provider agents can reuse.

## Why

A full custom CLI would duplicate mature S3 signing, retry, pagination, multipart, checksum, and transfer logic. One helper creates stable JSON output and aidevops safety semantics while delegating protocol maintenance to rclone.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Existing shell/config/test conventions apply, but argument validation, output normalization, redaction, and safe mutation handling need normal implementation judgment.

## PR Conventions

Use the normal closing keyword for issue #31685. Reference parent #31684 without closing it.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Issue-only dispatch is sufficient; no unverified code should anchor the worker.
- **Status:** not-created
- **Freshness evidence:** verified against `19d1897997ee7910458cfb9e768138977ba700f1`
- **Verification run:** unrun — implementation not started
- **Stale-assumption warning:** re-search for an object-storage helper or concurrent provider foundation before editing

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/aidevops/architecture.md:173-183` and `reference/high-stakes-operations.md` storage/deletion rules.
- **Load only if:** `reference/shell-style-guide.md` and `reference/bash-compat.md` while implementing shell parsing and tests.
- **Why:** preserve service-helper conventions, Bash 3.2 compatibility, and destructive-operation gates.
- **Stop when:** the command contract, config schema, fixture tests, and changed-file lint are clear.

### Worker Quick-Start

```bash
rg -n "confirm|dry-run|audit-log-helper|config.json.txt" .agents/scripts configs --glob '*.sh' --glob '*.json.txt'
command -v rclone
```

### Files to Modify

- `NEW: .agents/scripts/object-storage-helper.sh` — provider-neutral validated command surface using rclone
- `NEW: configs/object-storage-config.json.txt` — placeholder-only account aliases, provider, endpoint, region, and bucket allowlists
- `NEW: .agents/scripts/tests/test-object-storage-helper.sh` — fixture/mock tests with no live network or credentials
- `EDIT only if required: .agents/scripts/setup/_deploy_agents.sh or the actual setup deployment manifest discovered by search` — ensure the new helper deploys through existing broad script-copy behavior; do not edit if scripts are already copied generically

### Complete Write Surface

- **Callers/readers:** `.agents/services/hosting/idrive-e2.md`, `.agents/services/hosting/backblaze-b2.md`, and `.agents/services/hosting/wasabi.md` will call the helper contract delivered here.
- **Writers/mutation paths:** `.agents/scripts/object-storage-helper.sh` delegates only validated fixed operations to `rclone`; it never evaluates strings or accepts arbitrary flags.
- **Tests/fixtures:** `.agents/scripts/tests/test-object-storage-helper.sh` mocks `rclone` and asserts argv, JSON, redaction, dependency/config failures, bounds, dry-run, and confirmations.
- **Schemas/config:** `configs/object-storage-config.json.txt` defines placeholder-only aliases, provider, endpoint, region, remote reference, and bucket allowlists.
- **Generated/deployed mirrors:** `.agents/scripts/setup/_deploy_agents.sh` or the discovered broad script-copy path deploys source `.agents/`; never edit `~/.aidevops/agents/` directly.
- **Migrations/backfills:** no existing object-storage state exists; users opt in by creating ignored `configs/object-storage-config.json` and existing rclone remotes remain untouched.
- **Cleanup/rollback paths:** remove the new helper/template/test with `git revert`; no live storage migration or automatic cleanup is performed.

### Implementation Steps

1. Define commands: `readiness`, `list-buckets`, `list-objects`, `object-info`, `verify-backups`, `audit-protection`, `copy`, and `download`; keep destructive deletion/policy mutation blocked unless a later provider adapter adds an exact guarded operation.
2. Load accounts by explicit alias; fail when ambiguous or absent. Config contains no credentials and references secret-backed rclone remotes by generic alias.
3. Emit structured JSON on stdout and diagnostics on stderr. Bound listings and reject path traversal, control characters, raw URLs, arbitrary flags, and unknown providers.
4. Default transfer-changing commands to dry-run/preview. Require exact confirmation tokens under the high-stakes operation policy before irreversible provider adapters can call a mutation hook.
5. Redact remote/account identities and secrets from logs; audit consequential operations without credential values.
6. Add fixture tests and verify deployment behavior.

### Hazards and Compatibility

- **Concurrency/atomicity:** concurrent read-only verification is allowed; mutation commands serialize per target and never share temporary output paths.
- **Migration/rollback:** no state migration occurs and `git revert` removes the feature without touching user rclone configuration or remote objects.
- **Mixed-version/backward compatibility:** detect the installed rclone capabilities and report unsupported operations instead of guessing flags across versions.
- **Idempotency/retry:** read-only calls are replay-safe; write calls must not automatically retry after an ambiguous result and dry-run remains the default.
- **Partial failure/recovery:** preserve rclone's failed/resumable transfer status and report failure until exit status plus post-operation evidence proves success.
- Shell functions projected above 80 lines must be split before they exceed the repository's 100-line function gate.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-object-storage-helper.sh
shellcheck .agents/scripts/object-storage-helper.sh .agents/scripts/tests/test-object-storage-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** fixture tests cover helper/config/mutation behavior and all negative acceptance criteria; ShellCheck covers both shell files; changed-file lint covers the complete declared scope and deployment integration.
- **Broad verification trigger:** Not required unless implementation changes shared setup deployment logic beyond adding the helper to an existing explicit manifest.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `bash .agents/scripts/tests/test-object-storage-helper.sh`
- [ ] WIP commit created before broad gates: `wip: add object storage helper foundation`
- [ ] Evidence-triggered broad verification then run: not required unless shared setup deployment logic changes

### Files Scope

- `.agents/scripts/object-storage-helper.sh`
- `.agents/scripts/tests/test-object-storage-helper.sh`
- `configs/object-storage-config.json.txt`
- `.agents/scripts/setup/_deploy_agents.sh`

## Acceptance Criteria

- [ ] A fixture-backed `readiness` and `verify-backups` call returns stable JSON without exposing configured credentials or private account names.
- [ ] Missing rclone, unknown aliases/providers, malformed endpoints, unbounded listings, and arbitrary pass-through flags fail closed before execution.
- [ ] Write-capable paths produce a preview/dry-run by default and cannot perform an irreversible action without the exact confirmation contract.
- [ ] Tests prove the helper never edits existing rclone config and invokes only allowlisted rclone commands/arguments.

## Context

- rclone is the selected maintained S3 transport; do not build AWS Signature V4, XML parsing, multipart, pagination, retries, or transfer code.
- Cloudron continues to own actual backup creation and transfer. This helper verifies and administers remote storage; it does not impersonate Cloudron backup health.
