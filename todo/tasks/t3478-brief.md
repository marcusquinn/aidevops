<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3478: `_feedback/` plane parent — capture, retention, mining, and promotion paths

## Pre-flight

- [x] Memory recall: `issue 22285 full-loop` — no prior lesson found.
- [x] Discovery pass: related t2840/t2870/t2874 parent-plane work found; no existing `_feedback/` parent task found.
- [x] File refs verified: model on `todo/tasks/t2870-brief.md` and `todo/tasks/t2874-brief.md`.
- [x] Tier: `tier:thinking` — retention, sensitivity, and mining policy design; child phases should generally be `tier:standard`.

## Origin

- **Created:** 2026-05-02
- **Session:** Headless worker for GH#22285 / t3434
- **Created by:** ai-worker
- **Parent task:** none (this IS a parent)
- **Conversation context:** t2840 named `_feedback/` as a post-MVP plane, and `_campaigns` planning expects feedback insights to feed campaign research. A dedicated parent keeps raw signal, mining, and promotion workflows separate from durable knowledge.

## What

Establish `_feedback/` as the canonical plane for raw and processed qualitative signal: user comments, client feedback, support pain, survey responses, social comments, sales objections, product notes, and retrospective observations.

**This is a planning-only parent.** No ingestion, mining, or promotion code ships from this issue directly.

## Why

Feedback has a distinct lifecycle:

- **Raw signal first:** preserve the original statement, source, context, actor/segment, channel, and timestamp before interpretation.
- **Sensitivity-heavy:** feedback can contain personal, client, privileged, or reputationally sensitive content with different retention rules.
- **Mining required:** one comment is evidence; repeated themes become insight or work.
- **Promotion fan-out:** mined feedback can become `_knowledge/insights/`, `_campaigns` research, `_projects` requirements, `_cases` notes, or TODO/GitHub tasks.

Without a dedicated plane, feedback scatters across inbox notes, case files, campaign research, and memories, losing provenance and retention control.

## Tier

**Selected tier:** `tier:thinking` — this is decomposition design. Children will be smaller capture/mining/promotion implementation tasks.

## PR Conventions

This is a parent-task. Initial planning PR uses `For #` keyword (planning only). Children's PRs use `For #THIS-ISSUE` until the final phase, which uses a closing keyword for this parent.

## Children

- t3523 / #22510 — Phase 1: capture contract and normalized metadata fields.
- t3524 / #22512 — Phase 2: retention and sensitivity policy.
- t3525 / #22515 — Phase 3: mining workflow and evidence thresholds; filed as
  the child that documents clustering, deduplication, review gates, and promotion
  thresholds in `.agents/aidevops/feedback.md`.
- t3527 / #22518 — Phase 4: promotion paths into knowledge, campaigns, projects, cases, performance, and tasks.
- t3528 / #22519 — Phase 5: CLI and routines design (filed; design contract in `.agents/aidevops/feedback.md`).

## Phases

Decomposition planned as 5 phases:

- **Phase 1 — capture contract**: define `_feedback/captures/` and normalized fields for source, timestamp, actor/segment, context, channel, sentiment, sensitivity, and consent/retention.
- **Phase 2 — retention and sensitivity policy**: define which feedback can be long-lived, anonymized, privileged, client-scoped, or deleted; align with Markdoc sensitivity tags when available.
- **Phase 3 — mining workflow**: design clustering, deduplication, theme extraction, evidence thresholds, and review gates before promotion.
- **Phase 4 — promotion paths**: specify when feedback becomes `_knowledge/insights/`, a `_campaigns` research input, a `_projects` requirement, a `_cases` note, or a new TODO/GitHub task.
- **Phase 5 — CLI and routines**: design `aidevops feedback capture|list|mine|promote|retire` plus recurring mining/reporting cadence; child #22519 owns the design contract without closing parent #22373.

Children are filed above so parent-task automation can track progress. Each child remains independently scoped and may block on the data-plane registry or Markdoc tag work when implementation begins.

## Out of Scope (for this parent)

- Direct integrations with every feedback source (email, forms, app reviews, socials) — start with local capture contract.
- Fully automated task creation from single comments — mined themes need evidence thresholds and review gates.
- Sentiment-model vendor selection — defer until capture and retention contracts exist.

## Cross-Plane Connections

- `_knowledge/insights/` receives durable themes after mining and review.
- `_campaigns/active/<id>/research/` receives audience pain points and objections.
- `_projects/<id>/requirements/` receives validated product/project requirements.
- `_cases/<id>/feedback/` or case notes receive client-specific signal.
- `_performance/` receives qualitative context around metric movements.

## How (decomposition only — no code changes)

This parent ships:

- Decomposition plan in this brief.
- A parent GitHub issue with `## Phases` so parent-task automation can understand the tracker.
- Child issue links for each phase so the parent no longer stalls as an undecomposed tracker.
- TODO entry with `#parent` and `ref:GH#22373`.

### Files Scope

- `todo/tasks/t3478-brief.md` (this file — for the planning PR)
- `TODO.md` (parent entry only)

## Acceptance Criteria

- [ ] `_feedback/` has a parent issue/brief defining capture formats and required metadata.
- [ ] Retention and sensitivity policy goals are documented.
- [ ] Mining workflow and evidence thresholds are explicit.
- [ ] Promotion paths to `_knowledge`, `_campaigns`, `_projects`, `_cases`, and TODO/GitHub task creation are documented.
- [ ] TODO entry includes `ref:GH#22373`, `#parent`, and this brief link.
- [ ] Phase children are filed and linked from this parent brief.

## Context & Decisions

- **Why separate from `_knowledge/`:** raw feedback is not durable knowledge until mined, reviewed, and promoted.
- **Why separate from `_inbox/`:** `_inbox/` is staging/triage; `_feedback/` is the retained signal plane after classification.
- **Why evidence thresholds:** one complaint may be important, but automatic task creation needs repeatability or explicit human/agent review to avoid noise.

## Relevant Files

- `todo/tasks/t2870-brief.md` — `_campaigns` parent; feedback insights feed campaign research.
- `todo/tasks/t2874-brief.md` — Markdoc tag parent; likely structured annotation layer for feedback sensitivity/provenance.
- `todo/tasks/t3476-brief.md` — `_projects` parent; mined themes can become project requirements.
- `todo/tasks/t3477-brief.md` — `_performance` parent; feedback contextualizes results.

## Dependencies

- **Blocked by:** data-plane directory/registry foundation and sensitivity/Markdoc conventions for retained qualitative signal.
- **Coordinates with:** `_knowledge`, `_campaigns`, `_projects`, `_cases`, and `_performance`.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| This planning PR | ~20m | brief + issue + TODO |
| Future Phase 1-5 children | TBD | size after capture/retention contract is accepted |
| **Planning total** | **~20m** | |
