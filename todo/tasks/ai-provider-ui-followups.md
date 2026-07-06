# AI provider UI follow-up briefs

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Context

The AI Providers surface now presents the local aidevops OAuth pool as a grouped provider catalog with recommended badges for OpenAI, Cursor, and Z.ai. The implementation intentionally keeps provider actions read-only because GUI write routes for OAuth/account mutation need an audited command allowlist.

Inspiration reviewed from the public 9router and OmniRoute repositories: provider category chips, searchable provider catalogs, multi-account rows, health badges, per-account cooldown/error metadata, OAuth modal fallbacks, provider topology, and quota/resilience settings.

## Follow-up 1: Add audited provider write routes

### Goal

Allow the GUI to run safe, explicit provider actions for `connect account`, `rotate`, `check`, `reset cooldowns`, `remove`, and `set priority` without accepting arbitrary browser-provided shell commands.

### Files to inspect/modify

- `packages/gui-shared/src/contracts.ts` — add route manifest entries and request/response contracts.
- `packages/gui-api/src/app.ts` — add Hono routes that map fixed operation IDs to fixed helper invocations.
- `packages/gui-api/tests/status-route.test.ts` and `packages/gui-api/tests/security.test.ts` — prove write routes reject arbitrary commands/providers and redact secrets.
- `.agents/scripts/oauth-pool-helper.sh` and `.agents/plugins/opencode-aidevops/oauth-pool-tool.mjs` — reuse provider/action naming and supported operation semantics.

### Acceptance criteria

- Browser requests can select only known provider IDs and known actions.
- API never accepts raw shell, arbitrary args, token values, or callback URLs from the browser.
- GUI buttons become enabled only when their matching route is implemented and verified.
- Verification: `npm run gui:typecheck && npm run gui:test:api && npm run gui:test:security`.

## Follow-up 2: Wire Z.ai into the OAuth pool backend

### Goal

Make the Z.ai recommendation actionable by adding real OAuth or credential-pool backend support instead of a UI-only provider target.

### Files to inspect/modify

- `.agents/plugins/opencode-aidevops/oauth-pool-constants.mjs` — add provider constants only after verifying installed OpenCode/provider support.
- `.agents/plugins/opencode-aidevops/oauth-pool-tool.mjs` — extend provider enum and user guidance.
- `.agents/scripts/oauth-pool-helper.sh`, `.agents/scripts/oauth-pool-add.sh`, `.agents/scripts/oauth-pool-manage.sh`, and `.agents/scripts/oauth-pool-lib/` — add add/list/check/rotate/remove support.
- `packages/gui-api/src/status-adapter.ts` and `packages/gui-shared/src/contracts.ts` — keep GUI provider IDs aligned with backend support.

### Acceptance criteria

- Z.ai has the same account lifecycle coverage as the other pool providers or is explicitly represented as API-key-only with matching copy.
- Tests cover token redaction, provider enum validation, health checks, and unsupported-action failures.
- Verification: relevant `.agents/plugins/opencode-aidevops/tests/test-*oauth*.mjs`, `.agents/scripts/oauth-pool-lib/tests/test_pool_ops.py`, `npm run gui:test:adapters`, and `npm run gui:test:components`.

## Follow-up 3: Add provider topology, quotas, and resilience settings

### Goal

Surface how AI traffic moves through aidevops: session/runtime → agent/worker → provider pool account → model/provider family, with health and capacity signals.

### Files to inspect/modify

- `packages/gui-web/src/StatusSurfaces.tsx` — current provider catalog/card patterns.
- `packages/gui-web/src/PulseWorkersSurface.tsx` — worker/model telemetry patterns.
- `packages/gui-api/src/status-pulse-workers.ts` — token/cost/provider summary source data.
- `packages/gui-shared/src/contracts.ts` — add metadata-only topology/quota contracts.

### Acceptance criteria

- Topology exposes only metadata: provider IDs, model refs, account refs, status, cooldown, usage/cost refs.
- Quota/resilience settings are explanatory and read-only unless audited write routes exist.
- Verification: `npm run gui:typecheck && npm run gui:test:schema && npm run gui:test:components`.

## Follow-up 4: Extract a reusable integration/provider registry

### Goal

Move provider metadata out of `StatusSurfaces.tsx` into a reusable registry that can power AI providers, service integrations, and future icon sourcing.

### Files to inspect/modify

- `packages/gui-web/src/StatusSurfaces.tsx` — extract `AI_PROVIDER_CATALOG` and related types.
- `packages/gui-web/src/RecommendedAppsSurface.tsx` — existing icon-library import pattern.
- `packages/gui-shared/src/contracts.ts` — decide whether registry metadata belongs in shared contracts or web-only view metadata.
- `DESIGN.md` — keep provider icon and recommendation-badge rules current.

### Acceptance criteria

- Provider cards use one registry shape for display name, group, auth kind, recommendation, icon fallback, capabilities, and OpenCode prefixes.
- Third-party icon use has text fallback and does not hide brand names behind icon-only UI.
- Verification: `npm run gui:typecheck && npm run gui:test:components`.
