<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3476: `_projects/` plane parent — structured project lifecycle and TODO/full-loop integration

## Pre-flight

- [x] Memory recall: `issue 22285 full-loop` — no prior lesson found.
- [x] Discovery pass: related t2840/t2870/t2874 parent-plane work found; no existing `_projects/` parent task found.
- [x] File refs verified: model on `todo/tasks/t2870-brief.md` and `todo/tasks/t2874-brief.md`.
- [x] Tier: `tier:thinking` — architecture-level decomposition; child phases should generally be `tier:standard` once contracts are concrete.

## Origin

- **Created:** 2026-05-02
- **Session:** Headless worker for GH#22285 / t3434
- **Created by:** ai-worker
- **Parent task:** none (this IS a parent)
- **Conversation context:** t2840 established `_knowledge/` and `_cases/` as the MVP planes and explicitly named `_projects/`, `_performance/`, and `_feedback` as post-MVP planes. Later work references these planes, but they lacked dedicated trackers.

## What

Establish `_projects/` as the canonical user-data plane for structured project state: goals, plans, milestones, decisions, risks, links to TODO/full-loop tasks, and post-completion outcomes.

**This is a planning-only parent.** No code changes ship from this issue directly — children file individual implementation tasks once the MVP plane foundation is stable and this decomposition is ready to execute.

## Why

Project work has a distinct shape:

- **Different lifecycle:** `intake → scope → plan → implement → verify → release → learn → archive`.
- **Different audit needs:** every project should link to TODO entries, GitHub issues, PRs, releases, verification evidence, and post-completion decisions.
- **Different granularity:** a project may span multiple repos and multiple task IDs, while TODO entries remain atomic execution units.
- **Different consumers:** project managers, implementation agents, review agents, reporting routines, and future performance dashboards all need stable references.

Without a dedicated plane, project state either bloats TODO.md, gets buried in repo-local notes, or fragments across issues and PRs with no durable project-level index.

## Tier

**Selected tier:** `tier:thinking` — this is decomposition design. Implementation children will be smaller, mechanical tasks once the contract is pinned.

## PR Conventions

This is a parent-task. Initial planning PR uses `For #` keyword (planning only). Children's PRs use `For #THIS-ISSUE` until the final phase, which uses a closing keyword for this parent.

## Phases

Decomposition planned as 5 phases:

- **Phase 1 — directory contract**: define `_projects/<project-id>/` layout, required files, ID rules, and relation to existing repo-local `TODO.md` / `todo/` planning files.
- **Phase 2 — lifecycle mapping**: model project states from intake through planning, implementation, verification, completion, archive, and revival; define how state maps to GitHub issues, TODO entries, PRs, and full-loop evidence.
- **Phase 3 — CLI surface**: design `aidevops project new|list|status|link|archive` and the minimal project registry needed for cross-repo references.
- **Phase 4 — task and evidence links**: define durable references from project milestones to task IDs, GitHub issues, PRs, releases, verification commands, and worker outcomes.
- **Phase 5 — cross-plane integration**: specify when project outputs promote to `_knowledge/`, when client-facing work links to `_cases/`, and when results feed `_performance/`.

Children are NOT pre-filed. File them when the t2840 MVP foundation is stable and each phase has concrete file scopes.

## Out of Scope (for this parent)

- Building project management UI or dashboards — separate child/parent once schema exists.
- Replacing TODO.md or GitHub issues — `_projects/` links to execution artefacts; it does not become the execution queue.
- Cross-repo billing, capacity planning, or client reporting — likely `_performance/` / business-ops work.

## Cross-Plane Connections

- `_knowledge/insights/` receives durable project lessons and reusable decisions.
- `_cases/<id>/projects/` can link client-specific project work without duplicating project state.
- `_performance/projects/` receives outcome metrics after completion.
- `_feedback/` can promote mined themes into project requirements or risks.
- TODO.md and GitHub remain the execution/audit layer; `_projects/` is the project-level context layer.

## How (decomposition only — no code changes)

This parent ships:

- Decomposition plan in this brief.
- A parent GitHub issue with `## Phases` so parent-task automation can understand the tracker.
- TODO entry with `#parent` and `ref:GH#22371`.

### Files Scope

- `todo/tasks/t3476-brief.md` (this file — for the planning PR)
- `TODO.md` (parent entry only)

## Acceptance Criteria

- [x] `_projects/` has a parent issue/brief defining lifecycle, directory contract goals, and relation to TODO/full-loop.
- [x] TODO entry includes `ref:GH#22371`, `#parent`, and this brief link.
- [x] Phase children are not filed prematurely.
- [x] Cross-plane links to `_knowledge`, `_cases`, `_performance`, and `_feedback` are documented.

## Parent State

- **Verified:** 2026-05-03 — parent issue GH#22371 exists with `parent-task`, TODO.md contains the canonical linked entry, and this brief defines the future phase sequence.
- **Closure policy:** keep GH#22371 open while it is a planning parent; child implementation tasks should reference it with `For #22371` until the final phase is ready to close the parent.

## Context & Decisions

- **Why separate from TODO.md:** TODO.md tracks executable work; `_projects/` tracks context and lifecycle across many work items.
- **Why not a child of t2840:** t2840 already scoped the MVP data-plane foundation. `_projects/` is post-MVP and needs its own decomposition to avoid scope creep.
- **Why children not pre-filed:** phase file scopes depend on the data-plane registry and directory contract work now in flight.

## Relevant Files

- `todo/tasks/t2870-brief.md` — peer parent pattern for `_campaigns/`.
- `todo/tasks/t2874-brief.md` — peer parent pattern for structured tags.
- `TODO.md` — execution task index and audit references.

## Dependencies

- **Blocked by:** enough t2840/data-plane foundation to reuse directory and indexing conventions.
- **Coordinates with:** future `_performance/` and `_feedback/` parents.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| This planning PR | ~20m | brief + issue + TODO |
| Future Phase 1-5 children | TBD | size after data-plane registry lands |
| **Planning total** | **~20m** | |
