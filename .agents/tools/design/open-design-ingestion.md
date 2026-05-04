<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Open Design Skill Ingestion Plan

Source: [nexu-io/open-design](https://github.com/nexu-io/open-design) (Apache-2.0). This plan treats Open Design as an optional peripheral and evaluates each upstream skill for aidevops value before any import.

## Classification

| Action | Meaning |
|--------|---------|
| **Adopt** | High standalone value; ingest as a focused `*-skill.md` after compression and provenance capture |
| **Adapt** | Valuable but must be reshaped around aidevops `DESIGN.md`, verification, or domain agents |
| **Combine** | Merge into existing aidevops agent/workflow instead of adding a new skill |
| **Reference** | Keep as external inspiration or optional Open Design-only surface |
| **Defer** | Low priority, niche, duplicate, or dependent on unverified runtime assets |

## High-Value Ingestion Targets

| Skill | Upstream mode/scenario | aidevops action | Why |
|-------|------------------------|-----------------|-----|
| `web-prototype` | prototype/design | Adopt | General artifact-first web prototype entry point |
| `saas-landing` | prototype/marketing | Adopt | Strong overlap with marketing/CRO landing-page work |
| `dashboard` | prototype/operations | Adopt | Useful for admin, analytics, and ops UI mockups |
| `mobile-app` | prototype/design | Adopt | Extends mobile UI design with framed artifact generation |
| `mobile-onboarding` | prototype/design | Adopt | Common app growth/onboarding deliverable |
| `email-marketing` | prototype/marketing | Adapt | Pair with aidevops email testing and client-render checks |
| `social-carousel` | prototype/marketing | Adopt | Useful for social-media agent deliverables |
| `magazine-poster` | prototype/marketing | Adopt | Reusable poster/one-pager creative surface |
| `motion-frames` | prototype/marketing | Adapt | Bridge to Remotion/HyperFrames/video workflows |
| `wireframe-sketch` | prototype/design | Adopt | Cheap first-pass ideation before higher-fidelity work |
| `critique` | prototype/design | Combine | Fold into aidevops design review and UI verification rubrics |
| `tweaks` | prototype/design | Combine | Fold into iterative design refinement workflow |
| `guizang-ppt` | deck/marketing | Adopt | Proven magazine-style HTML deck skill with preserved license |
| `html-ppt` | deck/marketing | Adapt | Broad deck studio; convert to smaller style-specific aidevops skills |
| `html-ppt-pitch-deck` | deck/finance | Adopt | Direct business/fundraising value |
| `html-ppt-product-launch` | deck/marketing | Adopt | Useful launch/keynote deliverable |
| `html-ppt-tech-sharing` | deck/engineering | Adopt | Strong developer education/presentation fit |
| `weekly-update` | deck/operations | Adapt | Pair with reporting/routine agents |
| `hyperframes` | video/video | Adapt | Bridge with Remotion and video agents; verify toolchain first |
| `video-shortform` | video/marketing | Adapt | Valuable for social/video workflows after verification |
| `image-poster` | image/design | Adapt | Useful if connected to existing image-generation rules |

## Full Skill Matrix

| Skill | Recommended action | Notes |
|-------|--------------------|-------|
| `audio-jingle` | Defer | Potential brand/audio value; needs audio toolchain and rights review |
| `blog-post` | Combine | Existing content/SEO agents cover prose; use visual article layout patterns only |
| `critique` | Combine | Extract 5-dimensional critique into design verification prompts |
| `dashboard` | Adopt | Add as artifact skill with accessibility and dense-data checks |
| `dating-web` | Reference | Niche personal/consumer example; useful as pattern inspiration |
| `design-brief` | Combine | Fold discovery questions into brand identity and DESIGN.md creation |
| `digital-eguide` | Adapt | Useful for lead magnets; align with document/content agents |
| `docs-page` | Adapt | Merge with docs-site and developer documentation workflows |
| `email-marketing` | Adapt | Require `email-design-test-helper.sh` verification before completion |
| `eng-runbook` | Combine | Existing incident/runbook agents should own operational correctness |
| `finance-report` | Adapt | Pair with accounts/business agents and data provenance checks |
| `gamified-app` | Reference | Good mobile interaction inspiration; lower broad demand |
| `guizang-ppt` | Adopt | Keep upstream license; flatten assets/references per build-agent rules |
| `hatch-pet` | Defer | Codex pet spritesheet niche; import only if user demand appears |
| `hr-onboarding` | Adapt | Useful document artifact; combine with HR/process templates |
| `html-ppt-course-module` | Adapt | Good education/training deck variant |
| `html-ppt-dir-key-nav-minimal` | Reference | Style variant; absorb into deck style catalogue |
| `html-ppt-graphify-dark-graph` | Reference | Style variant for dev-tool/keynote decks |
| `html-ppt-hermes-cyber-terminal` | Reference | Style variant for CLI/review decks |
| `html-ppt-knowledge-arch-blueprint` | Reference | Style variant for architecture decks |
| `html-ppt-obsidian-claude-gradient` | Reference | Style variant for developer workflow decks |
| `html-ppt-pitch-deck` | Adopt | High-value fundraising deck surface |
| `html-ppt-presenter-mode-reveal` | Adapt | Presenter notes and speaker mode useful; verify popup/export behaviour |
| `html-ppt-product-launch` | Adopt | High-value launch/keynote surface |
| `html-ppt-taste-brutalist` | Reference | Convert to DESIGN.md/style archetype rather than skill |
| `html-ppt-taste-editorial` | Reference | Convert to DESIGN.md/style archetype rather than skill |
| `html-ppt-tech-sharing` | Adopt | High-value technical presentation surface |
| `html-ppt-testing-safety-alert` | Adapt | Useful security/risk deck style; pair with security agents |
| `html-ppt-weekly-report` | Adapt | Good routine/status reporting output |
| `html-ppt-xhs-pastel-card` | Reference | Social-style deck variant; keep as style reference |
| `html-ppt-xhs-post` | Adapt | Useful social carousel/deck hybrid for marketing agent |
| `html-ppt-xhs-white-editorial` | Reference | Style variant; fold into social/deck style catalogue |
| `html-ppt` | Adapt | Split into concise aidevops deck subskills instead of one broad prompt |
| `hyperframes` | Adapt | Integrate only after local render/lint smoke checks |
| `image-poster` | Adapt | Needs image-generation provider/toolchain mapping |
| `invoice` | Combine | Existing accounts/document agents own invoice correctness |
| `kanban-board` | Reference | Visual snapshot only; project systems remain source of truth |
| `magazine-poster` | Adopt | High-value one-page marketing artifact |
| `meeting-notes` | Combine | Existing productivity/workflow agents own meeting record correctness |
| `mobile-app` | Adopt | Strong product design fit |
| `mobile-onboarding` | Adopt | Strong growth/product design fit |
| `motion-frames` | Adapt | Bridge to Remotion/video verification |
| `pm-spec` | Combine | Existing PRD/spec templates should remain canonical |
| `pptx-html-fidelity-audit` | Adopt | Strong utility for deck export verification |
| `pricing-page` | Adopt | Useful sales/CRO page artifact |
| `replit-deck` | Reference | Product-deck style variant |
| `saas-landing` | Adopt | High-value marketing surface |
| `simple-deck` | Adapt | Useful baseline deck skill; avoid overlap with `html-ppt` |
| `social-carousel` | Adopt | Strong social-media deliverable |
| `sprite-animation` | Reference | Niche; keep as animation inspiration |
| `team-okrs` | Combine | Existing planning/business agents own OKR semantics |
| `tweaks` | Combine | Fold into design iteration workflow |
| `video-shortform` | Adapt | Pair with video prompt design, Remotion, and platform specs |
| `web-prototype-taste-brutalist` | Reference | Convert style to DESIGN.md archetype |
| `web-prototype-taste-editorial` | Reference | Convert style to DESIGN.md archetype |
| `web-prototype-taste-soft` | Reference | Convert style to DESIGN.md archetype |
| `web-prototype` | Adopt | Core preview/prototype surface |
| `weekly-update` | Adapt | Useful reporting deck once wired to routines |
| `wireframe-sketch` | Adopt | Low-cost design discovery artifact |

## Ingestion Order

1. **Design artifact MVP**: `web-prototype`, `wireframe-sketch`, `critique`, `tweaks`.
2. **Marketing surfaces**: `saas-landing`, `pricing-page`, `social-carousel`, `magazine-poster`, `email-marketing`.
3. **Decks**: `guizang-ppt`, `html-ppt-pitch-deck`, `html-ppt-product-launch`, `html-ppt-tech-sharing`, `pptx-html-fidelity-audit`.
4. **Mobile/product**: `mobile-app`, `mobile-onboarding`, `dashboard`.
5. **Media**: `motion-frames`, `hyperframes`, `video-shortform`, `image-poster` after toolchain verification.

## Optimisation Rules

- Keep each imported skill below ~100 always-read instructions; move examples/assets into side files.
- Replace Open Design UI-only metadata with aidevops routing notes unless needed by `/open-design`.
- Add verification commands to every adopted skill: UI screenshot, accessibility, email, deck export, or render smoke test.
- Prefer existing aidevops agents for semantics; imported skills should improve artifact craft, not duplicate domain reasoning.
