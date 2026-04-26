<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2870: `_campaigns/` plane — marketing assets, intel, inspiration for ads + organic campaigns

## Pre-flight

- [x] Memory recall: "parent task decomposition phase children filing" — confirmed pattern (parent-task label + #parent + ## Phases heading required)
- [x] Discovery pass: no existing `_campaigns/` work in flight
- [x] File refs verified: pattern source `t2840-brief.md` (peer parent-task)
- [x] Tier: `tier:thinking` — architecture-level decomposition; child phases will be `tier:standard`

## Origin

- **Created:** 2026-04-25
- **Session:** Claude Code interactive session
- **Created by:** ai-interactive (per user request — peer parent to t2840)
- **Parent task:** none (this IS a parent)
- **Conversation context:** During t2840 architecture review, user identified that marketing/ads work doesn't fit cleanly in `_knowledge/` (too active), `_cases/` (reactive client work), or `_projects/` (different lifecycle phases, different agents, different asset types). Filed as separate parent so MVP scope (`_knowledge/` + `_cases/`) ships first; campaigns plane follows once foundation is live.

## What

Establishes `_campaigns/` as a peer-level user-data plane for marketing/advertising/outreach work. Houses brand assets, competitive intel, inspiration swipe files, in-flight campaign creative, and post-launch performance + learnings. Cross-plane integration: `_feedback/` insights feed campaign research, campaign learnings promote to `_knowledge/insights/`, performance metrics flow to `_performance/`.

**This is a planning-only parent.** No code changes ship from this issue directly — children file individual implementation tasks once MVP foundation (t2840) is live.

## Why

Marketing/campaign work has distinct shape:

- **Different lifecycle:** `concept → research → creative → review → distribution → measure → learn` (not the build-test-ship cycle of `_projects/`).
- **Different agents:** creative director, copywriter, market researcher, distributor — none apply to typical software projects.
- **Different sensitivity profile:** competitive intel is its own tier (never cloud); pre-launch creative is confidential; post-launch creative is public.
- **Asset binary heavy:** logos, video, audio — heavy use of the `~/.aidevops/.agent-workspace/knowledge-blobs/` 30MB-threshold path.
- **Swipe-file pattern:** "I saved this because [creative reason]" with channel/mood metadata — doesn't fit `_knowledge/` reference shape.

Without a dedicated plane, marketing work either bloats `_projects/` (wrong lifecycle) or scatters across the filesystem unmanaged.

## Tier

**Selected tier:** `tier:thinking` — this is decomposition design. Children will be `tier:standard`.

## PR Conventions

This is a parent-task. Initial planning PR uses `For #` keyword (planning only). Children's PRs use `For #THIS-ISSUE` until the final phase, which uses `Closes #THIS-ISSUE`.

## Phases

Decomposition planned as 6 phases (children filed when t2840 MVP exits):

- Phase 1 — `_campaigns/` directory contract + sub-folder structure (`lib/`, `intel/`, `active/`, `launched/`)
- Phase 2 — campaign CLI surface (`aidevops campaign new|list|status|launch|archive`) + campaign-id provisioning
- Phase 3 — sensitivity tier integration (`competitive` tier added to P0.5a sensitivity classifier; intel sub-folder enforces local-LLM-only)
- Phase 4 — asset binary integration (large files routed to `~/.aidevops/.agent-workspace/knowledge-blobs/`; thumbnail/preview generation)
- Phase 5 — AI creative agent (`aidevops campaign draft <id> --channel <name>`) — RAG-grounded in `lib/brand/`, human-gated, channel-aware
- Phase 6 — performance integration + learnings promotion (`launched/<id>/results.md` → `_performance/marketing/`; `learnings.md` → `_knowledge/insights/marketing/`)

Children NOT pre-filed — files when t2840 MVP exits. Each phase will get its own brief + GH issue + auto-dispatch tag at that point. This parent stays open as a tracker.

## Out of Scope (for this parent)

- Channel-specific publishing integrations (Meta Ads API, Google Ads API, LinkedIn API, etc.) — separate parent post-`_campaigns/` MVP
- Distribution opt-in templates (chase-style, similar to `_cases/` chase) — separate parent
- A/B test analysis / multi-variant attribution — separate parent
- Post-launch performance dashboards — uses `_performance/` plane (separate parent)

## Cross-Plane Connections

- `_feedback/` insights → input to `_campaigns/active/<id>/research/audience-pain.md`
- `_knowledge/insights/marketing/` ← campaign post-mortem learnings (promotion)
- `_performance/marketing/` ← campaign post-launch metrics
- `_cases/<client>/campaigns/<id>/` (agency model) → references shared `_campaigns/active/<id>/` to avoid duplication
- `_inbox/` (P2 of t2840) → triage routes campaign-relevant captures (saved ads, inspiration) to `_campaigns/lib/swipe/`

## How (decomposition only — no code changes)

This parent ships:

- Decomposition plan in this brief
- Phase headings in the issue body so the auto-decomposer recognises it as decomposed
- Cross-references to t2840 dependencies so each child knows its prerequisites

Phase implementation follows once MVP foundation (t2840 children) lands.

### Files Scope

- `todo/tasks/t2870-brief.md` (this file — for the planning PR)

## Acceptance Criteria

- [ ] Issue filed with `parent-task` label, `## Phases` heading, no-auto-dispatch.
- [ ] Brief committed at `todo/tasks/t2870-brief.md`.
- [ ] TODO entry with `ref:GH#NNN`.
- [ ] Phase children NOT yet filed (deliberate — wait for t2840 MVP exit).
- [ ] Cross-references to t2840 phases documented in brief.

## Context & Decisions

- **Why a separate parent vs P-phase of t2840:** scope discipline. t2840 is already 20 children; adding campaigns ~6 more would push delivery further out. Campaigns is post-MVP-of-MVP work — file the parent now to capture intent, ship after foundation is solid.
- **Why filed now if not implemented now:** architectural intent is fragile. Documenting the plane shape and cross-plane connections now (while design is fresh) prevents drift when implementation starts months later.
- **Why phases not pre-filed:** children would block on t2840 + age in backlog. File them when foundation lands and prerequisites are concrete.
- **Why `_campaigns/lib/` separate from `_knowledge/`:** brand assets (logos, fonts, voice/tone) are reusable across campaigns; they're library not reference. `_knowledge/` reference items are for retrieval and citation, different access pattern.
- **Why `_campaigns/intel/` not `_knowledge/competitive/`:** competitive intel has its own sensitivity tier (`competitive`), distinct retention policy (months not years), and distinct retrieval pattern (campaign-scoped, not topic-scoped).

## Relevant Files

- `t2840-brief.md` — MVP foundation; this plane builds on its directory contract pattern
- `t2846-brief.md` (P0.5a sensitivity) — `competitive` tier added here for `_campaigns/intel/`
- `t2848-brief.md` (P0.5c Ollama) — local-only LLM substrate for intel
- `t2849-brief.md` (P1a kind-aware enrichment) — pattern reference for asset metadata extraction

## Dependencies

- **Blocked by:** t2840 (knowledge planes MVP) — needs directory contract pattern, sensitivity layer, LLM routing, kind-aware enrichment all live before campaigns can ship
- **Blocks:** none directly (post-MVP work)
- **External:** none in MVP; full implementation will need creative review human-gate workflows

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| This planning PR | ~30m | brief + issue + TODO |
| Future Phase 1-6 children | TBD | sized when filed (estimate ~25-35h total across 6 phases) |
| **Planning total** | **~30m** | |
