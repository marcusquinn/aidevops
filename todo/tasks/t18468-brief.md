<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18468: Self-host prospecting packaging, agent routing and parity handoff

## Pre-flight

- [x] Memory recall: no relevant lessons in parent queries.
- [x] Discovery pass: previous planning PR #32071 merged; t18458 owns earlier marketing root routing and must finish before this integration.
- [x] File refs verified: seo.md, marketing-sales.md, domain-index, build-agent, routines and local-hosting guidance exist.
- [x] Tier: standard; package delivered contracts and wire existing routing, not a new deployment/control plane.
- [x] Seeded draft PR skipped: all predecessor interfaces must be real before packaging.

## Origin

2026-09-20 interactive background brief. Parent: t18459. blocked-by:t18467,t18458 (#32070). User reserves general AnyAPI/site-scraping expansion for a separate session.

## What

Deliver documented native local and self-hosted operation, optional container packaging, discoverable subagents/command/API/MCP instructions and a verified feature-parity handoff for the complete prospecting workflow.

## Why

Ensure the capability is installable and usable as aidevops—not an integration with Lurk, a collection of unconnected scripts or a mandatory paid SaaS dependency.

## Tier

**Selected tier:** `tier:standard` — final integration follows delivered contracts; no unresolved auth/architecture boundary should remain.

## How

### Files to Modify

- `NEW: .agents/marketing-sales/prospecting.md` — native coordinator/capability matrix.
- `NEW: .agents/scripts/commands/prospecting.md` — command entry point.
- `NEW: .agents/services/hosting/prospecting-self-host.md` — local/container deployment and recovery.
- `NEW: .agents/templates/prospecting-container/Dockerfile` — minimal unprivileged package.
- `NEW: .agents/templates/prospecting-container/compose.yaml` — persistent volumes and loopback host-port default.
- `NEW: .agents/templates/prospecting-container/env.example` — placeholders and secret-handle instructions only.
- `EDIT: .agents/marketing-sales.md` — prospecting entry pointer.
- `EDIT: .agents/seo.md` — Reddit SEO entry pointer.
- `EDIT: .agents/reference/domain-index.md` — narrow intent routing.
- `NEW: .agents/scripts/tests/test-prospecting-integration.py` — focused offline chain verification.

Read `.agents/tools/build-agent/build-agent.md`, `.agents/reference/routines.md`, `.agents/services/hosting/local-hosting.md`, the delivered service/MCP contract and current container guidance. Verify current runtime/SDK requirements before pinning packaging; do not expand into global runtime maintenance or publish images automatically.

### Files Scope

- `.agents/marketing-sales/prospecting.md`
- `.agents/scripts/commands/prospecting.md`
- `.agents/services/hosting/prospecting-self-host.md`
- `.agents/templates/prospecting-container/Dockerfile`
- `.agents/templates/prospecting-container/compose.yaml`
- `.agents/templates/prospecting-container/env.example`
- `.agents/marketing-sales.md`
- `.agents/seo.md`
- `.agents/reference/domain-index.md`
- `.agents/subagent-index.toon`
- `.agents/scripts/tests/test-prospecting-integration.py`
- `.agents/scripts/tests/fixtures/prospecting/integration.json`

### Complete Write Surface

- **Callers/readers:** domain coordinators and `.agents/scripts/commands/prospecting.md` route to delivered CLI/UI/service surfaces.
- **Writers/mutation paths:** scoped source/docs/container templates and generated `.agents/subagent-index.toon`; no live runtime configuration.
- **Tests/fixtures:** test-prospecting-integration.py and `.agents/scripts/tests/fixtures/prospecting/integration.json`, plus predecessor focused tests.
- **Schemas/config:** consume `.agents/configs/prospecting.schema.json` and prospecting-openapi.json; no global provider/model settings.
- **Generated/deployed mirrors:** regenerate `.agents/subagent-index.toon` from the source worktree; no deployed agent or canonical service edits.
- **Migrations/backfills:** `.agents/scripts/prospecting-project-helper.py` owns documented backup/restore/schema operations; no real user data migration during tests.
- **Cleanup/rollback paths:** `.agents/services/hosting/prospecting-self-host.md` documents stop with retained volumes and explicit backup-aware deletion; never automatic volume removal.

### Implementation Steps

1. Add concise pointers under existing agents and a command that chooses onboarding, scan, leads, Reddit SEO, insights, alerts, usage, API/MCP or workbench. Reuse #32065 and prior shared decision/report paths; do not duplicate prompts or launch one agent per row.
2. Provide local-first startup with synthetic/offline mode and optional unprivileged container composition. Preserve private project storage, health/readiness, secret injection and graceful shutdown; bind host ports to loopback by default. No mandatory Clerk, AnyAPI, Lurk, hosted database, cloud wallet or model subscription.
3. Document authorized provider setup through existing aidevops capability/secret tools, current costs/unknowns, per-project caps, retention/export/backup/restore, pausing scans and revoking API keys. No credentials in templates/logs/images and no automatic scheduler installation.
4. External hosting requires explicit TLS/auth/network/exposure review; public launch is separate authority. Provide MCP client setup instructions without editing global host configuration or auto-connecting it.
5. Execute one offline end-to-end scenario: product evidence -> reviewed discovery plan -> incremental post/comment/rules capture -> #32065 scoring -> inbox dispositions -> SERP/competitor/themes -> usage/digest preview -> scoped API/MCP/UI. Assert profile edits/rescoring preserve feedback and no external messages are sent.
6. Publish a parity matrix distinguishing implemented behavior, provider-dependent availability, observed test evidence and excluded AnyAPI/scraping work. Actual AI citations and ROI remain separately measured; never claim the reference app's marketing outcome is guaranteed.

### Hazards and Compatibility

- **Concurrency/atomicity:** wait for prior routing owner t18458; packaged service/routines retain existing single-project lease rules.
- **Migration/rollback:** backup/restore verified on synthetic storage; stopping/upgrading does not delete volumes or silently downgrade auth.
- **Mixed-version/backward compatibility:** validate actual helper/schema/SDK versions and fail incompatible images/config explicitly.
- **Idempotency/retry:** setup/generator repeat safely without duplicate agents, schedules or provider activation.
- **Partial failure/recovery:** preserve checkpoints/volumes and remaining criteria; unavailable live providers use explicit recorded coverage, not fabricated parity.

### Verification Before Dispatch

```bash
python3 .agents/scripts/tests/test-prospecting-integration.py
docker compose -f .agents/templates/prospecting-container/compose.yaml config --quiet
AIDEVOPS_AGENTS_DIR="$PWD/.agents" .agents/scripts/subagent-index-helper.sh generate
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** integration test drives real offline CLI/service contracts; validate/build/start the minimal container in a bounded isolated fixture project when Docker is available, verify health/persistence/stop/restore and UI via existing browser tooling. Run existing subagent validation. No image publication or live account access.
- **Recovery:** checkpoint focused evidence before further gates; Docker/provider absence is reported with the exact remaining runtime check and safe continuation, never replaced by a claim of verified self-hosting.

## Acceptance Criteria

- [ ] Native CLI, agent routing, workbench, scoped REST/MCP and local/container setup are documented and exercised through the offline parity scenario.
- [ ] Private data survives restart/upgrade/restore checks, and default schedules, external exposure and alert delivery remain disabled until explicit operator activation.
- [ ] No Lurk/AnyAPI dependency, generic scraping-platform implementation, surprise spend, secret-in-image or automatic public engagement is introduced.
