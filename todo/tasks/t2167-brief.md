---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2167: Add video SEO agent with transcript-seo + video-schema subagents

## Origin

- **Created:** 2026-04-17
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (Marcus directing)
- **Conversation context:** Distilling two industry articles (marketingagent.blog 2026 YouTube SEO guide + vdocipher.com video SEO best practices) into reusable agent guidance. Current SEO agents cover page/image/GEO; YouTube agents cover channel ops and CTR; nothing covers video-as-content-atom optimised for simultaneous ranking across YouTube native + Google Search (Key Moments) + LLM answer engines.

## What

Three new agent docs that distil video SEO guidance into maximum-information-density reference cards, plus cross-reference pass across 11 existing agents so related work discovers the new capability:

1. `seo/video-seo.md` — main agent. Three-surface model (YouTube / Google / LLM), orchestrates the other two subagents plus existing agents.
2. `seo/transcript-seo.md` — transcript-as-retrieval-signal discipline. Reusable by video, audio, podcast, YouTube script writer, and hallucination defense.
3. `seo/video-schema.md` — `VideoObject`, `Clip`, `Speakable`, `FAQPage`/`HowTo` with video. Reusable by rich-results, schema-validator, programmatic-seo, blog distribution with embedded video.

Plus a stale-path fix in root `AGENTS.md` (sidebar fold-in): table intro says "See `.agents/aidevops/`" but four of six rows live at `.agents/tools/...`.

## Why

- Video is now a content atom that ranks across three surfaces simultaneously; existing agents only cover one surface each.
- Transcripts are the primary LLM retrieval signal (both articles converge on this); currently treated as a UX/accessibility feature, not a ranking signal.
- Video schema is generic in `rich-results`/`schema-validator` with no video-specific playbook.
- Without cross-refs, the new work is invisible to content/YouTube/SEO workflows that need it.
- Build-agent-style decomposition into main + two reusable subagents prevents single-agent bloat and enables other agents (audio, podcast, programmatic-seo) to call the subagents independently.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? (13 files — 3 new, 10 edits)
- [x] Every target file under 500 lines?
- [ ] Exact oldString/newString for every edit? (author-discretion prose additions)
- [ ] No judgment or design decisions? (content composition is judgment work)
- [x] No error handling or fallback logic to design?
- [x] No cross-package or cross-module changes?
- [ ] Estimate 1h or less? (~2h)
- [x] 4 or fewer acceptance criteria?

**Selected tier:** `tier:standard`

**Tier rationale:** Writing three new agent docs from distilled source material requires content judgment (what to include, what to defer, how to phrase rules tersely). Not mechanical transcription. Interactive session — not dispatched.

## PR Conventions

Leaf issue. PR body will use `Resolves #NNN`.

## How (Approach)

### Files to Modify

- `NEW: .agents/seo/video-seo.md` — main video SEO agent, ~130 lines, model on `seo/image-seo.md`
- `NEW: .agents/seo/transcript-seo.md` — transcript discipline subagent, ~90 lines
- `NEW: .agents/seo/video-schema.md` — video schema playbook subagent, ~110 lines
- `EDIT: AGENTS.md:37-46` — stale-path fix
- `EDIT: .agents/seo.md` — add three subagents to roster + capability line
- `EDIT: .agents/seo/geo-strategy.md` — video assets cross-ref
- `EDIT: .agents/seo/ai-search-readiness.md` — video row in scorecard
- `EDIT: .agents/seo/rich-results.md` — cross-ref to video-schema
- `EDIT: .agents/seo/schema-validator.md` — cross-ref to video-schema
- `EDIT: .agents/content.md` — supporting tools table row
- `EDIT: .agents/content/distribution-youtube.md` — related agents row
- `EDIT: .agents/content/distribution-youtube-optimizer.md` — multi-surface pointer
- `EDIT: .agents/content/distribution-youtube-topic-research.md` — question-framed angle type row
- `EDIT: .agents/content/distribution-youtube-script-writer.md` — spoken-keyword discipline pre-flight + pointer
- `EDIT: .agents/content/distribution-short-form.md` — separate KW strategy pointer
- `EDIT: .agents/content/production-video.md` — pre-production keyword-aware scripting note

### Implementation Steps

1. Write three new agent docs, modelled on `seo/image-seo.md` structure (YAML, AI-CONTEXT block, terse tables, minimal examples, integration points).
2. Apply AGENTS.md stale-path fix.
3. Apply 11 cross-ref edits — each additive, audited for non-duplication.
4. Run `markdownlint-cli2` on new and edited files.
5. Run `.agents/scripts/linters-local.sh` sanity check.
6. Commit in logical chunks, push, open PR with `Resolves #NNN`.

### Verification

```bash
# All three new agent files exist
test -f .agents/seo/video-seo.md && test -f .agents/seo/transcript-seo.md && test -f .agents/seo/video-schema.md

# Cross-refs land
grep -q "video-seo" .agents/seo.md
grep -q "video-schema" .agents/seo/rich-results.md
grep -q "transcript-seo\|video-seo" .agents/content/distribution-youtube.md

# AGENTS.md sidebar fix applied
grep -q "^See \`\.agents/\` for" AGENTS.md

# Markdown lints clean
bunx markdownlint-cli2 ".agents/seo/video-seo.md" ".agents/seo/transcript-seo.md" ".agents/seo/video-schema.md"
```

## Acceptance Criteria

- [ ] Three new agent docs written, each under ~150 lines, following `seo/image-seo.md` reference-card pattern with zero duplication of content already in sibling agents.
- [ ] All 11 existing agents updated with single-purpose cross-references (no content lift).
- [ ] AGENTS.md stale-path bug fixed.
- [ ] All touched files pass markdownlint-cli2.
