<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18467: Native prospecting operator web workbench

## Pre-flight

- [x] Memory recall: no relevant lessons in parent queries.
- [x] Discovery pass: repo DESIGN.md and UI verification guidance reviewed; worker-status dashboards are not a prospecting app to duplicate.
- [x] File refs verified: DESIGN.md, design-md.md, ui-verification.md and frontend-debugging.md exist; scoped assets are new.
- [x] Tier: standard; build UI against delivered service contracts and established aidevops design tokens.
- [x] Seeded draft PR skipped: actual service endpoints must merge first.

## Origin

2026-09-20 interactive background brief. Parent: t18459. blocked-by:t18465,t18466. Native aidevops UI, not Lurk branding/assets/code or a new hosted SaaS.

## What

Provide a lightweight self-hosted operator interface for projects, onboarding, sources, lead review, Reddit SEO, competitors/themes, alerts, usage/activity and settings, backed by the native service.

## Why

Deliver the practical app workflow requested, not merely disconnected CLI helpers, while keeping default operation local and privacy-aware.

## Tier

**Selected tier:** `tier:standard` — established tokens and delivered backend contract; responsive/accessibility implementation still requires judgment.

## How

### Files to Modify

- `NEW: .agents/templates/prospecting-workbench/index.html` — native app shell and views.
- `NEW: .agents/templates/prospecting-workbench/app.js` — typed service interaction and state rendering.
- `NEW: .agents/templates/prospecting-workbench/styles.css` — responsive aidevops styling.
- `EDIT: DESIGN.md` — concise durable workbench patterns and responsive behavior.
- `NEW: .agents/marketing-sales/prospecting-workbench.md` — operator workflow and evidence handoff.

Apply `DESIGN.md` black/cyan/system-font tokens and existing cards/inputs. Read `.agents/tools/design/design-md.md`, `.agents/workflows/ui-verification.md`, `.agents/tools/ui/frontend-debugging.md` and relevant accessibility guidance before implementation. No copied Lurk visual identity, remote avatars/favicons or tracking assets. This is a lightweight operator surface; do not introduce React/Next/Clerk/Postgres just to mirror the reference deployment.

### Files Scope

- `.agents/templates/prospecting-workbench/index.html`
- `.agents/templates/prospecting-workbench/app.js`
- `.agents/templates/prospecting-workbench/styles.css`
- `DESIGN.md`
- `.agents/marketing-sales/prospecting-workbench.md`

### Complete Write Surface

- **Callers/readers:** operator browser loads only assets served by `prospecting_api.py`; CLI remains independently usable.
- **Writers/mutation paths:** `app.js` calls delivered owner-only typed controls; no direct database/secret/provider access.
- **Tests/fixtures:** use predecessor `.agents/scripts/tests/fixtures/prospecting/api.json` and existing browser-qa/accessibility tooling; no new browser-test framework.
- **Schemas/config:** REST contract `.agents/configs/prospecting-openapi.json`; visuals follow `DESIGN.md`.
- **Generated/deployed mirrors:** source assets deploy via `setup.sh` and final packaging; no generated bundle or live deployment is edited.
- **Migrations/backfills:** N/A because presentation introduces no database or auth migration.
- **Cleanup/rollback paths:** revert scoped assets and `DESIGN.md` addition; existing CLI/service records remain intact.

### Implementation Steps

1. Build project switcher and URL/snapshot/manual onboarding with editable product facts, provenance, missing evidence and candidate-versus-active queries/communities. Display job progress and errors instead of fictional success while profile/scan runs.
2. Lead inbox groups threads with independently scored comments, reasons, matching quotes, intent/fit/engagement, source permalink, observed age, rules freshness and coverage. Filter by project/date/community/stage/score/disposition. Saved/hidden/not-fit/reviewed/responded controls change local workflow only.
3. Add Reddit SEO query/position/history views with filtered-versus-organic labels, open/locked/archived state and competitor evidence. Competitor/pain views drill into source records; do not turn observed mentions into market-share or conversion claims.
4. Add sources, activity, usage/budget, schedule and alert configuration views. Show remaining/estimated/unknown cost and explicit pause/enable controls; manual scans require configured authority/budget. Key metadata may be displayed, never real credentials. No public reply/DM composer or send controls.
5. Implement empty/loading/partial/offline/error/expired-session states and optimistic updates with server conflict reconciliation. Render captured text as text, sanitize links and never load arbitrary remote media or execute embedded source instructions.
6. Record responsive decisions: accessible keyboard navigation, visible focus, readable mobile cards, large-screen dense tables, safe long text and 200% zoom. Update DESIGN.md in the same PR and visually verify the rendered app, not only HTTP status.

### Hazards and Compatibility

- **Concurrency/atomicity:** backend versions guard stale edits; UI reports conflicts and refreshes rather than silently overwriting.
- **Migration/rollback:** static presentation only; reverting assets preserves CLI/API/store operation.
- **Mixed-version/backward compatibility:** check API version and feature availability; unsupported controls are disabled with reasons.
- **Idempotency/retry:** repeated clicks reuse request identities and show in-flight state; do not queue duplicate paid scans.
- **Partial failure/recovery:** preserve unsaved edits locally only where safe, label stale data and fail closed on expired auth; no guessed success.

### Verification Before Dispatch

```bash
python3 .agents/scripts/prospecting-service-helper.py --help
.agents/scripts/browser-qa-helper.sh --help
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** start the existing service with synthetic project fixtures in a bounded process; use existing browser QA to exercise onboarding, filters/dispositions, SEO/insights and settings at desktop/mobile. Capture viewport screenshots at max 1568px, inspect console/network errors, keyboard/focus/contrast and 200% zoom. Use installed JS checks; do not add one-off test infrastructure.
- **Recovery:** checkpoint functional/browser evidence and preserve remaining UI criteria after a fuse. No live provider, production deployment or user-data screenshot is required.

## Acceptance Criteria

- [ ] The rendered workbench completes the synthetic onboarding-to-lead-review-to-insight workflow across all named views.
- [ ] Desktop/mobile keyboard and accessibility checks have evidence, with clear partial/error/stale/conflict states.
- [ ] No source-text execution, remote tracking media, secret display, unauthorized control or public engagement capability is introduced.
