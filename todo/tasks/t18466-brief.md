<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18466: Scoped prospecting service APIs, read-only MCP and operator boundary

## Pre-flight

- [x] Memory recall: no relevant lessons in parent queries.
- [x] Discovery pass: existing MCP authoring and domain contracts reviewed; no prospecting service exists.
- [x] File refs verified: build-mcp guidance, secret handling and foundation briefs exist; new service paths below.
- [x] Tier: thinking; project-scoped authentication, read-versus-operator authority and serving untrusted source text need explicit security design.
- [x] Seeded draft PR skipped: no speculative auth implementation seed.

## Origin

2026-09-20 interactive background brief. Parent: t18459. blocked-by:t18465. Wait for its delivered job/usage contract (including t18463/t18464 transitively), rather than inventing a parallel queue. Native service; no Lurk-compatible client, AnyAPI dependency or hosted identity requirement.

## What

Expose the native project/lead/SEO/insight/usage read model through versioned REST/OpenAPI and read-only MCP, with a separate authenticated operator boundary for local project/lead settings and bounded job requests.

## Why

Provide agent/API access and a backend for the workbench without allowing read credentials or untrusted conversations to trigger writes, spending or arbitrary commands.

## Tier

**Selected tier:** `tier:thinking` — design and prove scope/auth/transport boundaries and fail-closed behavior.

## How

### Files to Modify

- `NEW: .agents/scripts/prospecting-service-helper.py` — loopback-default service lifecycle CLI.
- `NEW: .agents/scripts/prospecting_api.py` — typed read and operator HTTP routes.
- `NEW: .agents/scripts/prospecting_auth.py` — project-scoped key/session handling.
- `NEW: .agents/scripts/prospecting_mcp.py` — thin read-only protocol adapter using a supported official SDK.
- `NEW: .agents/configs/prospecting-openapi.json` — versioned REST schema.
- `NEW: .agents/configs/prospecting-requirements.txt` — isolated pinned optional service dependencies if required.
- `NEW: .agents/tools/mcp-toolkit/prospecting.md` — service/client contract and setup.
- `NEW: .agents/scripts/tests/test-prospecting-api.py` — focused transport/auth tests.

Read `.agents/tools/build-mcp/build-mcp.md`, its server-patterns/transports/api-wrapper references, `.agents/reference/secret-handling.md` and the delivered prospecting contract. Verify installed SDK version/exports; do not build a custom MCP protocol or silently change global runtime configuration. Prefer the smallest adapter compatible with the Python domain helpers; document dependency/transport trade-offs.

### Files Scope

- `.agents/scripts/prospecting-service-helper.py`
- `.agents/scripts/prospecting_api.py`
- `.agents/scripts/prospecting_auth.py`
- `.agents/scripts/prospecting_mcp.py`
- `.agents/configs/prospecting-openapi.json`
- `.agents/configs/prospecting-requirements.txt`
- `.agents/tools/mcp-toolkit/prospecting.md`
- `.agents/scripts/tests/test-prospecting-api.py`
- `.agents/scripts/tests/fixtures/prospecting/api.json`

### Complete Write Surface

- **Callers/readers:** REST/MCP clients and future static workbench use `prospecting_api.py` projections, not direct DB access.
- **Writers/mutation paths:** `prospecting_auth.py` owns private key metadata; authenticated operator routes invoke only typed foundation mutations/job requests.
- **Tests/fixtures:** `.agents/scripts/tests/test-prospecting-api.py` and API fixture use synthetic keys and isolated stores.
- **Schemas/config:** `.agents/configs/prospecting-openapi.json` plus shared domain schema and isolated optional requirements.
- **Generated/deployed mirrors:** source `.agents/tools/mcp-toolkit/prospecting.md` documents optional clients; no automatic registration, external binding or deployed/user config edits.
- **Migrations/backfills:** `.agents/scripts/prospecting_auth.py` owns new private auth metadata and explicit service-local versions, preserving the foundation store.
- **Cleanup/rollback paths:** `.agents/scripts/prospecting-service-helper.py` stop and key revocation invalidate access; removal preserves evidence and never exposes an unauthenticated fallback.

### Implementation Steps

1. Implement health, project list/detail, filtered/paginated lead list/detail, Reddit SEO observations, competitor/themes, activity and usage read routes. Include score/reason/evidence/source/cost metadata and explicit coverage. Document stable pagination/as-of, errors and schema version.
2. Scope read tokens to explicit project IDs and permissions; hash/rotate/revoke safely, store secrets only through existing secure tooling. Default loopback binding and no anonymous data; cross-project/unknown IDs must not leak existence. Rate/response-size limits, parameterized queries and audited sanitized failures apply.
3. Expose matching MCP read tools with accurate read-only annotations. Read tokens/tools cannot start scans, modify feedback/settings, create tokens, post/DM or run shell/SQL/URLs. Reject extra arguments and arbitrary file references. Source content is inert untrusted text, never agent authority.
4. Define a distinct owner/operator session boundary for project creation, profile/source edits, local lead disposition, alert configuration and bounded manual job requests. Protect CSRF, Origin/Host, session expiry and sensitive actions; validate enums/IDs/budgets server-side. A boolean supplied by a client/model is not owner approval. No generic command execution endpoint.
5. Serve only allowlisted UI assets from the later workbench directory with safe MIME/CSP/path handling. Escape evidence text and disable remote tracking assets. External deployment requires explicit bind/TLS/auth configuration; no hosted auth provider or public launch by default.
6. Document optional client configuration without installing/activating it. Operator-visible key provisioning must not print real secrets into agent-visible transcripts; verify with synthetic credentials.

### Hazards and Compatibility

- **Concurrency/atomicity:** auth revocation/edit races and store CAS must be rechecked at operation boundaries; read requests have no hidden writes/spend.
- **Migration/rollback:** version service auth state independently; revoke keys on explicit teardown, never migrate to weaker auth silently.
- **Mixed-version/backward compatibility:** validate domain/REST/MCP versions and SDK exports; unsupported routes fail explicitly.
- **Idempotency/retry:** stable read pagination and idempotent typed job-request IDs; no duplicate scan on HTTP retry.
- **Partial failure/recovery:** failed auth/backend/model readiness leaves service closed or returns bounded unavailable, never arbitrary fallback execution.

### Verification Before Dispatch

```bash
python3 .agents/scripts/prospecting-service-helper.py --help
python3 .agents/scripts/tests/test-prospecting-api.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** run the actual isolated service and SDK protocol client against fixture data; tests cover HTTP/MCP queries, schema/pagination, token revocation/scope, denied writes, CSRF/SSRF/traversal, malicious source text and no read-triggered spend. Reuse existing Python test pattern and installed SDK tooling.
- **Recovery:** checkpoint focused verified work; preserve remaining criteria after a safety stop. Do not bypass missing authority or expose a public service to prove completion.

## Acceptance Criteria

- [ ] Authenticated scoped REST/MCP reads return the same project/lead/SEO/insight/usage data as the native CLI with published schemas.
- [ ] Owner-only typed controls support the workbench while read tokens and MCP tools remain incapable of mutations or paid job requests.
- [ ] No unauthorized/cross-project access, credential leakage, arbitrary execution, implicit public exposure or Lurk/AnyAPI/hosted-auth dependency is introduced.
