<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2874: structured tag format for knowledge planes (Markdoc-style peer parent)

## Pre-flight

- [x] Memory recall: "structured content format markdown tags schema" — no prior aidevops work on this; BaseHub uses Markdoc for similar problem (audited 2026-04-26 in t2840 design session)
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch any `markdoc-*` path or tag-validator surface — greenfield primitive
- [x] File refs verified: pattern source `t2870-brief.md` (peer parent-task), `t2849-brief.md` (P1a kind-aware enrichment — produces tagged content), `t2850-brief.md` (P1c PageIndex — consumes tagged content)
- [x] Tier: `tier:thinking` — architecture-level decomposition; child phases will be `tier:standard`

## Origin

- **Created:** 2026-04-26
- **Session:** Claude Code interactive session
- **Created by:** ai-interactive (per user request — peer parent to t2840)
- **Parent task:** none (this IS a parent)
- **Conversation context:** During t2840 follow-up review, user asked whether BaseHub-style headless content patterns (Markdoc tags, structured fields, schema validation) could apply to our knowledge planes. Analysis concluded: format matters for agent reliability even within a file+git architecture — loose markdown gives no validation, no agent-stable extraction surface, no schema-driven consumers. PageIndex (t2850) already provides the navigation skeleton; Markdoc-style tags provide the inline semantic layer that lifts to navigation metadata. The two compose. Filed as separate parent so MVP scope (t2840) ships first; tag format follows once foundation is live and a real consumer (P1c) is wired to receive tag attributes.

## What

Establishes a Markdoc-compatible tag format as the canonical structured-content layer across all knowledge planes (`_knowledge/`, `_cases/`, `_projects/`, `_performance/`, `_feedback/`, `_campaigns/`, `_inbox/`). Tags declare semantic regions (sensitivity stamps, citations, case-attach edges, provenance, redaction, draft status) inside otherwise-prose markdown files. A schema-driven validator runs at write time (pre-commit + CLI), an extractor produces a tag-position JSON sidecar for agent consumption, and existing planes consume tag attributes via dedicated read paths (PageIndex node metadata, retrieval filters, draft provenance footers).

**This is a planning-only parent.** No code changes ship from this issue directly — children file individual implementation tasks once t2840 MVP foundation is live (P0a/P0b/P0c minimum + P1a/P1c so there's a real consumer to wire).

## Why

Loose markdown gives the agent no reliable surface for:

- **Sensitivity stamps inline** — today sensitivity lives in `meta.json`; a region within a longer document inherits the file-level stamp. Markdoc tags let a single source carry multiple sensitivity scopes (a public document quoting one privileged paragraph), which the routing layer (t2847) can honour exactly.
- **Citation graph** — drafts need to cite source IDs verbatim with confidence + page anchors. Today this is a regex pass over text. Markdoc `{% citation %}` blocks make citations structurally explicit, parser-friendly, and round-trippable.
- **Case-attach edges** — content that lives in `_knowledge/` but is relevant to one or more cases needs an edge structure that survives renames and forks. Tag attributes give that.
- **Schema enforcement at write time** — a worker drafting a `case chase` template can be blocked at commit if the template lacks `{% draft-status status="..." /%}` and `{% provenance %}`. No retroactive cleanup; bad tags never enter the corpus.
- **Indexing-by-tag** — t2850 PageIndex already builds a per-document tree with summaries; tag attributes promote to per-node metadata so retrieval can filter by `sensitivity=privileged AND case=acme-dispute` without re-reading bodies.
- **Format migration** — when the schema evolves (new sensitivity tier, new tag), a migration tool can rewrite tag attributes deterministically. With loose markdown, migration is regex + human review.

PageIndex (t2850) is the navigation skeleton; Markdoc tags are the inline semantic labels. Together they give the agent a structured queryable corpus without leaving file+git. Without this layer, every consumer reinvents extraction (and they will all do it differently).

**Concrete trigger:** P1a (t2849) currently emits `text.txt + meta.json`. Without a tag format, structured fields extracted at ingestion time (sender, receipt date, sensitivity classification) are split between the prose body (extracted text) and the sidecar JSON — two sources of truth, drift-prone. With tag format, P1a emits one canonical `source.md` with tags for what was extracted, and `meta.json` becomes a slim sidecar for non-tag-suitable fields (file hash, byte size, blob pointer).

## Tier

**Selected tier:** `tier:thinking` — this is decomposition design. Children will be `tier:standard` (validators, extractors, schema migrations are mechanical once shape is set).

## PR Conventions

This is a parent-task. Initial planning PR uses `For #` keyword (planning only). Children's PRs use `For #THIS-ISSUE` until the final phase, which uses `Closes #THIS-ISSUE`.

## Phases

Decomposition planned as 7 phases. Children file when t2840 MVP exits (specifically: P0a + P0b + P0c + P1a + P1c must be merged so there is a real producer-consumer pair to wire tags through).

- **Phase 1 — tag schema** — define namespace and JSON schemas under `.agents/tools/markdoc/schemas/`. Initial set: `sensitivity`, `provenance`, `case-attach`, `citation`, `redaction`, `draft-status`, `link`. Each schema declares attributes (required + optional + types), scope rules (file / section / inline), and example.
- **Phase 2 — validator** — `scripts/markdoc-validate.sh validate <file>` — parses tagged file, checks well-formed tags + schema conformance + scope rules; pre-commit hook integration; CI gate. Detailed error context (file:line:column + which schema rule failed).
- **Phase 3 — extractor** — `scripts/markdoc-extract.sh extract <file>` — outputs tag-stripped plain text + JSON sidecar of `[{tag, attrs, scope, char_start, char_end}, ...]`. Optional `--tree` produces hierarchical tag tree (file scope → section scope → leaf scope) for structural traversal.
- **Phase 4 — migration** — port P0a (t2843) `meta.json + text.txt` layout onto `source.md` (tagged) + slim `meta.json`. Backwards-compat reader so existing sources keep working until migrated.
- **Phase 5 — PageIndex consumer** — wire P1c (t2850) to lift Markdoc tag attributes into PageIndex node `metadata`. Tag scope rules: file-level → root + all descendants; section-level → that node + descendants; inline → leaf node attribute. Citation tags become tree-level cross-references.
- **Phase 6 — retrieval consumer** — wire P5/P6 retrieval (`aidevops case draft`, `aidevops knowledge search`) to filter and rank by tag attributes (e.g. `--sensitivity privileged --case acme-dispute`).
- **Phase 7 — tooling** — IDE LSP for tag autocomplete + schema validation in editor; gh comment renderer that pretty-prints or strips tags when reproducing source content in PR/issue threads.

Children NOT pre-filed — files when t2840 MVP exits and the producer-consumer pair (P1a → P1c) is live. Each phase will get its own brief + GH issue + auto-dispatch tag at that point. This parent stays open as a tracker.

## Out of Scope (for this parent)

- Markdoc runtime adoption (the JS library) — we want the syntax + schema discipline, not the JS dependency. Validator + extractor are shell + jq + python.
- Rich rendering (HTML, MDX, React components) — content stays as markdown for human + agent consumption; rendering is a phase 7 niche concern.
- Tag-namespace versioning + deprecation semantics — handled when first breaking schema change lands; not pre-emptive.
- Cross-runtime tag discovery (Gitea, GitLab) — relies on platform abstraction in t2840 P0b, which already exists in MVP.
- Bidirectional sync with structured-content CMSes (BaseHub, Sanity, Storyblok) — separate parent if ever needed.

## Cross-Plane Connections

- `_knowledge/sources/<id>/source.md` (post-migration) — tagged canonical text; `meta.json` slimmed to non-tag fields
- `_cases/<id>/timeline/*.md` — tagged with `{% case-attach %}`, `{% citation %}`, `{% draft-status %}`
- `_inbox/staging/*.md` — provisional `{% sensitivity tier="unverified" /%}` until P2c triage reclassifies
- `_campaigns/active/<id>/creative/*.md` — tagged with `{% sensitivity tier="competitive" /%}`, `{% draft-status %}`, `{% link target="..." kind="brand-asset" /%}`
- `_feedback/captures/*.md` — tagged with `{% provenance %}`, `{% sensitivity %}` so retention policy can scope by tag

## How (decomposition only — no code changes)

This parent ships:

- Decomposition plan in this brief
- Phase headings in the issue body so the auto-decomposer recognises it as decomposed
- Cross-references to t2840 dependencies (P0a/P1a/P1c specifically) so each child knows its prerequisites

Phase implementation follows once t2840 MVP foundation lands and the producer-consumer pair (t2849 + t2850) is live.

### Files Scope

- `todo/tasks/t2874-brief.md` (this file — for the planning PR)

## Acceptance Criteria

- [ ] Issue filed with `parent-task` label, `## Phases` heading, `no-auto-dispatch` label.
- [ ] Brief committed at `todo/tasks/t2874-brief.md`.
- [ ] TODO entry with `ref:GH#NNN`.
- [ ] Phase children NOT yet filed (deliberate — wait for t2840 MVP exit + P1a/P1c live).
- [ ] Cross-references to t2849 (P1a producer) and t2850 (P1c consumer) documented in brief.
- [ ] Forward-compat hooks documented in t2849 + t2850 briefs (so when phase 4 + phase 5 land, the wiring already has named extension points).

## Context & Decisions

- **Why a separate parent vs P-phase of t2840:** scope discipline. t2840 is already 20 children + a peer parent (t2870 campaigns). Folding tag format into t2840 would push delivery further out and re-open scope on already-filed children. Cleaner to ship MVP loose-markdown, then upgrade to structured tags as v2 once consumers exist.
- **Why filed now if not implemented now:** architectural intent is fragile and forward-compat hooks need to be designed in BEFORE producers/consumers freeze their interface. Documenting tag-aware extension points in t2849 (producer) and t2850 (consumer) now keeps them additive when phase 4 + phase 5 land.
- **Why phases not pre-filed:** children would block on t2840 MVP exit + age in backlog. File them when foundation lands and prerequisites (P1a + P1c live) are concrete.
- **Why Markdoc syntax specifically vs invented tags:** Markdoc has well-documented `{% tag attr="value" %}` and `{% /tag %}` block grammar with mature parsers (JS, Ruby), MIT licence, and stable schema-validation semantics. Adopting the syntax convention costs nothing and lets us inherit the parsing precedent without taking on the JS runtime. Inventing a new format costs design + parser + documentation.
- **Why `source.md + meta.json` not single-file `.bshb`-style:** BaseHub uses single-file-per-item (binary + metadata + content together). That fights our binary/text-separation design (large blobs route to `~/.aidevops/.agent-workspace/knowledge-blobs/`, binary diffs are git-hostile). Directory-per-source with `source.md` + `meta.json` + `extracted.json` + `tree.json` keeps each artefact diff-friendly and tool-friendly.
- **Why validator-first not extractor-first:** extractor without validator means malformed tags silently produce empty extractions (RAG looks like it works but has missing data). Validator-first means malformed tags fail loudly at write time; extractor only sees well-formed input.
- **Why migration is its own phase:** a flag-day migration of all sources is risky on a corpus we haven't sized yet. Phase 4 ships migration tooling + a backwards-compat reader; sources migrate incrementally as they're re-touched, with a deadline tracked in TODO.

## Relevant Files

- `t2840-brief.md` — MVP foundation; tag format builds on its directory contract (`_knowledge/sources/<id>/`)
- `t2843-brief.md` (P0a directory contract) — current `meta.json + text.txt` layout that phase 4 migrates
- `t2849-brief.md` (P1a kind-aware enrichment) — producer; phase 4 makes it emit `source.md` instead of (or alongside) `text.txt`
- `t2850-brief.md` (P1c PageIndex tree) — consumer; phase 5 makes node `metadata` carry tag attributes
- `t2870-brief.md` (campaigns peer parent) — same peer-parent shape (parent-task, no-auto-dispatch, ## Phases, children-not-pre-filed)
- `.agents/tools/document/extraction-schemas/10-classification.md` — taxonomy reference; tag schemas may align with kind-classification

## Dependencies

- **Blocked by:** t2840 MVP foundation (specifically t2843 + t2849 + t2850 must merge — directory contract + producer + consumer)
- **Blocks:** none directly (post-MVP work; existing planes work fine with loose markdown until phase 4 migrates them)
- **External:** none in MVP; Markdoc syntax reference: <https://markdoc.dev/> (canonical spec, MIT)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| This planning PR | ~30m | brief + issue + TODO |
| Future Phase 1-7 children | TBD | sized when filed (estimate ~30-40h total across 7 phases — schema design dominates phase 1, validator + extractor ~6-8h each, migration is the big one at ~8-12h) |
| **Planning total** | **~30m** | |
