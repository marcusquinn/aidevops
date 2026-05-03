<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t3537: Define `_performance` KPI/result schema

## Pre-flight

- [x] Memory recall: `_performance KPI schema` → 0 hits — no prior lessons found.
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch `.agents/aidevops/performance.md` or this brief.
- [x] File refs verified: `.agents/aidevops/knowledge-plane.md` exists; `.agents/aidevops/performance.md` and this brief were absent before this task; parent #22372 is open and references #22538 under `## Children`.
- [x] Tier: `tier:thinking` — this is schema design, not a mechanical edit.
- [x] Seeded draft PR decision recorded: skipped — issue body already contains worker-ready context and this worker is implementing directly.

## Origin

- **Created:** 2026-05-03
- **Session:** OpenCode headless worker for issue #22538
- **Created by:** ai-worker
- **Parent task:** t3477 / #22372
- **Conversation context:** Parent #22372 decomposes the future `_performance/` plane. This child implements Phase 1 by documenting the KPI/result schema before directory layout, ingest, CLI, or dashboard phases proceed.

## What

Create `.agents/aidevops/performance.md` as the initial `_performance/` plane contract for KPI/result records. The document defines metric identity, subject and dimensions, measurement units, timestamps, confidence/source provenance, and baseline comparison semantics.

## Why

Campaigns, cases, projects, routines, and system health will all emit measurable outcomes. Without a shared result schema, each plane would invent incompatible metric shapes, blocking later ingest paths and dashboard/reporting work.

## Tier

**Selected tier:** `tier:thinking` — the deliverable is a schema contract with design trade-offs. It touches two Markdown files and does not require dispatch-path elevation.

## PR Conventions

This is a leaf child issue. The implementation PR uses `Resolves #22538`. Parent #22372 must remain open until later phases complete.

## How (Approach)

### Files to Modify

- `NEW: .agents/aidevops/performance.md` — initial `_performance/` KPI/result schema contract, modelled on `.agents/aidevops/knowledge-plane.md` document style.
- `NEW: todo/tasks/t3537-brief.md` — child implementation brief with files scope and verification.

### Implementation Steps

1. Add `.agents/aidevops/performance.md` with a Phase 1-only scope statement.
2. Define a canonical result-record shape with these top-level groups:
   - `metric` — stable identity, domain, kind, label, owner, and version.
   - `subject` and `dimensions` — measured entity plus orthogonal reporting slices.
   - `measurement` — value, unit, aggregation, precision, direction, and timestamps.
   - `quality` — confidence, source type/ref, collector, evidence, and caveats.
   - `baseline` — target/control/previous-period comparisons, deltas, and status.
3. Explicitly defer directory layout, ingest paths, CLI, dashboards, review cadence, and knowledge-promotion workflows to later phases.
4. Keep parent #22372 open and verify it references this child under `## Children`.

### Files Scope

- `.agents/aidevops/performance.md`
- `todo/tasks/t3537-brief.md`

### Verification

- `npx --yes markdownlint-cli2 .agents/aidevops/performance.md todo/tasks/t3537-brief.md`
- `gh issue view 22372 --repo marcusquinn/aidevops --json state,body --jq '.state + " " + ((.body | contains("#22538")) | tostring)'`

## Acceptance Criteria

- [x] KPI/result schema documented.
- [x] Metric identity and dimensions documented.
- [x] Units, timestamps, confidence/source documented.
- [x] Baseline comparison model documented.
- [x] Out-of-scope phases explicitly deferred.

## Context & Decisions

- **Representation-neutral schema:** Phase 1 defines field semantics before choosing Markdown, JSONL, or dashboard-specific storage. This prevents the directory-contract phase from hardcoding a premature storage format.
- **Metric identity separated from dimensions:** IDs stay stable across campaigns, cases, projects, and periods; volatile slices belong in `subject` and `dimensions` so future reports can aggregate correctly.
- **Baselines included now:** Result values without targets, controls, or previous-period comparisons are weak dashboard inputs. Baseline semantics are foundational enough to belong in Phase 1.
- **Deferred implementation:** No helper, ingest, dashboard, or CLI code is added in this phase because those depend on later parent phases.

## Relevant Files

- `.agents/aidevops/knowledge-plane.md` — reference document style for plane contracts.
- `.agents/aidevops/performance.md` — new KPI/result schema contract.
- `todo/tasks/t3537-brief.md` — this child brief.

## Dependencies

- **Parent:** #22372 tracks the full `_performance/` plane decomposition.
- **Blocks:** later `_performance/` directory, ingest, reporting CLI, and dashboard/review phases.
- **External:** none.

## Estimate Breakdown

| Work item | Time | Notes |
|-----------|------|-------|
| Schema contract | ~45m | Define fields, examples, and out-of-scope boundaries |
| Brief and verification | ~15m | Worker-ready context plus markdown lint |
| **Total** | **~1h** | Design-only child implementation |
