<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3477: `_performance/` plane parent — KPI schemas, dashboards, and result ingest

## Pre-flight

- [x] Memory recall: `issue 22285 full-loop` — no prior lesson found.
- [x] Discovery pass: related t2840/t2870/t2874 parent-plane work found; no existing `_performance/` parent task found.
- [x] File refs verified: model on `todo/tasks/t2870-brief.md` and `todo/tasks/t2874-brief.md`.
- [x] Tier: `tier:thinking` — schema and reporting architecture; child phases should generally be `tier:standard`.

## Origin

- **Created:** 2026-05-02
- **Session:** Headless worker for GH#22285 / t3434
- **Created by:** ai-worker
- **Parent task:** none (this IS a parent)
- **Conversation context:** `_campaigns` planning routes launched results to `_performance/`, while t2840 named `_performance/` as a post-MVP plane. A dedicated parent keeps metrics, reporting, and ingest contracts visible.

## What

Establish `_performance/` as the canonical plane for measurable outcomes: KPIs, result snapshots, experiment metrics, dashboard inputs, trend reports, and promotion paths from campaign launches, case outcomes, and project completions.

**This is a planning-only parent.** No ingest or dashboard code ships from this issue directly.

## Why

Results data has a distinct shape:

- **Numeric + temporal:** metrics need units, timestamps, windows, baselines, and confidence/source metadata.
- **Cross-plane ingest:** campaigns, cases, projects, and system routines all produce outcomes that should compare cleanly.
- **Reporting consumers:** dashboards and recurring reviews need stable schemas, not ad hoc Markdown tables.
- **Learning loop:** metric deltas should promote lessons back to `_knowledge/insights/` and trigger follow-up tasks when thresholds are missed.

Without a dedicated plane, every source plane will invent its own result format and dashboards will become brittle scrapers.

## Tier

**Selected tier:** `tier:thinking` — this is decomposition design. Children will be smaller schema/helper/dashboard tasks.

## PR Conventions

This is a parent-task. Initial planning PR uses `For #` keyword (planning only). Children's PRs use `For #THIS-ISSUE` until the final phase, which uses a closing keyword for this parent.

## Phases

Decomposition planned as 5 phases:

- **Phase 1 — KPI/result schema**: define metric identity, dimensions, units, timestamps, confidence/source, and comparison baselines.
- **Phase 2 — directory contract**: define `_performance/<domain>/` layout for marketing, cases, projects, system health, and future domains.
- **Phase 3 — ingest paths**: specify how `_campaigns/launched/<id>/results.md`, `_cases/<id>/outcomes/`, and `_projects/<id>/outcomes/` promote into performance records.
- **Phase 4 — reporting CLI**: design `aidevops performance ingest|list|report|dashboard` and JSON/Markdown outputs suitable for agents and humans.
- **Phase 5 — dashboard and review workflow**: define recurring reporting cadence, stale-metric detection, threshold alerts, and promotion of lessons back to `_knowledge/insights/`.

Children are NOT pre-filed. File them when upstream plane contracts and the data-plane registry make file scopes concrete.

## Out of Scope (for this parent)

- External analytics API integrations (Google Ads, Meta Ads, GA4, Stripe, etc.) — separate children after local schema exists.
- BI frontend selection — defer until schema and CLI reporting prove the data shape.
- Automated business decisions from metrics — reporting first, automation later.

## Cross-Plane Connections

- `_campaigns/launched/<id>/results.md` promotes marketing performance.
- `_cases/<id>/outcomes/` promotes client/case results.
- `_projects/<id>/outcomes/` promotes delivery outcomes.
- `_knowledge/insights/` receives lessons and interpretation from metric review.
- `_feedback/` can provide qualitative context for metric movements.

## How (decomposition only — no code changes)

This parent ships:

- Decomposition plan in this brief.
- A parent GitHub issue with `## Phases` so parent-task automation can understand the tracker.
- TODO entry with `#parent` and `ref:GH#22372`.

### Files Scope

- `todo/tasks/t3477-brief.md` (this file — for the planning PR)
- `TODO.md` (parent entry only)

## Acceptance Criteria

- [ ] `_performance/` has a parent issue/brief defining KPI/result schemas.
- [ ] Dashboard/reporting goals and review cadence are documented.
- [ ] Ingest paths from campaigns, cases, and projects are explicit.
- [ ] TODO entry includes `ref:GH#22372`, `#parent`, and this brief link.
- [ ] Phase children are not filed prematurely.

## Context & Decisions

- **Why separate from `_knowledge/`:** metrics are operational records and time-series evidence; `_knowledge/` stores durable insights after interpretation.
- **Why separate from `_campaigns/`:** campaign results are one input domain; the performance plane must also handle cases, projects, and system outcomes.
- **Why dashboard later:** dashboard choice should follow stable schemas, not drive them.

## Relevant Files

- `todo/tasks/t2870-brief.md` — `_campaigns` parent; phase 6 routes results here.
- `todo/tasks/t3476-brief.md` — `_projects` parent; project outcomes route here.
- `todo/tasks/t3478-brief.md` — `_feedback` parent; qualitative context for metric interpretation.

## Dependencies

- **Blocked by:** data-plane directory/registry foundation and upstream plane contracts.
- **Coordinates with:** `_campaigns`, `_projects`, `_cases`, `_feedback`, and `_knowledge` insights promotion.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| This planning PR | ~20m | brief + issue + TODO |
| Future Phase 1-5 children | TBD | size after upstream result producers are concrete |
| **Planning total** | **~20m** | |
