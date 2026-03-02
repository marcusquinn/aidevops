# t1373: Create brand identity bridge agent

## Origin

- **Created:** 2026-03-01
- **Session:** claude-code:interactive
- **Created by:** marcus (human, ai-interactive)
- **Parent task:** none (sibling of t1371, t1372)
- **Conversation context:** User identified the gap between design agents (colours, typography, layout) and content agents (copywriting, imagery, video). No shared brand definition exists — a designer picks "Glassmorphism + Trust Blue" but the copywriter doesn't know that means "confident, technical, concise." The brand identity bridge solves this by defining a per-project identity that all agents read. User also noted that brand character comes from copywriting style, imagery, iconography, and media — not just visual design.

## What

Create `.agents/tools/design/brand-identity.md` — a bridge agent that defines per-project brand identity covering both visual and verbal dimensions. This is the single source of truth that design agents, content agents, and production agents all reference.

The file contains:

1. **Brand Identity Template** — the schema for per-project `context/brand-identity.toon` files that live in each project repo. Dimensions:

   | Dimension | Design side | Content side |
   |-----------|------------|--------------|
   | **Visual style** | UI style (from catalogue), colour palette, typography pairing | — |
   | **Voice & tone** | — | Register (formal/casual/technical), vocabulary level, sentence style, humour, personality traits |
   | **Copywriting patterns** | — | CTA language, headline style, paragraph structure, power words, words to avoid |
   | **Imagery** | Photography vs illustration vs 3D, style/mood, filters, aspect ratios | Image subjects, composition preferences, stock vs custom |
   | **Iconography** | Icon library (Lucide/Heroicons/Phosphor/custom), style (outline/filled/duotone), sizing scale, stroke width | — |
   | **Buttons & forms** | Button variants (border-radius, padding, transitions, shadows), form field style, focus rings, validation states | CTA button copy patterns, form label voice, error message tone |
   | **Media & motion** | Video style, animation approach (subtle/bold), transition timing, loading patterns | Video tone, pacing, music mood, narration style |
   | **Brand positioning** | Premium vs accessible, playful vs serious, innovative vs established | Same — this is the shared axis that aligns design and content |

2. **Agent Integration Instructions** — how each agent type should read and apply the brand identity:
   - Design agents: read visual style, buttons & forms, iconography, media & motion sections
   - Content agents: read voice & tone, copywriting patterns, imagery, media & motion sections
   - Production agents (image/video/audio): read imagery, iconography, media & motion, brand positioning sections
   - All agents: read brand positioning (the shared axis)

3. **Brand Identity from Scratch Workflow** — when no brand identity exists:
   - Run the style interview from t1372's ui-ux-inspiration.md
   - Synthesise visual findings into the template
   - Interview user on verbal identity (tone, vocabulary, personality)
   - Interview user on imagery preferences (show examples from different styles)
   - Generate draft brand-identity.toon, present to user for approval
   - Save to project's `context/brand-identity.toon`

4. **Brand Identity from Existing Site** — when rebranding or extending:
   - Run URL study workflow from t1372 on the existing site
   - Extract current visual and verbal identity
   - Present findings to user: "Here's what your current brand identity looks like"
   - Ask what to keep, what to change, what to add
   - Generate updated brand-identity.toon

5. **Relationship Map** — how this file connects to existing agents:
   - `content/guidelines.md` — becomes the *default* copywriting voice when no brand identity exists. When a brand identity is present, guidelines.md provides the structural rules (paragraph length, HTML formatting, SEO bolding) while brand-identity.toon provides the voice.
   - `content/platform-personas.md` — adapts the brand voice per channel. Reads brand-identity.toon for the base voice, then applies platform-specific shifts.
   - `content/production/image.md` — reads imagery and iconography sections for generation parameters (style, mood, colour palette, composition).
   - `content/production/characters.md` — reads brand positioning and imagery for character design alignment.
   - `content/humanise.md` — applies after content generation to remove AI patterns, but respects the brand voice (doesn't flatten personality).
   - `workflows/ui-verification.md` — quality gates apply regardless of brand identity. Brand identity adds constraints on top, never relaxes them.

## Why

- **The gap is real**: design and content agents currently operate independently. A project can have beautiful UI with copy that reads like a different brand.
- **Per-project, not global**: `content/guidelines.md` is hardcoded to one client (Trinity Joinery). The brand identity system is parameterised — each project gets its own.
- **Single source of truth**: Without this, brand decisions are scattered across conversation history, lost between sessions. The TOON file persists in the project repo.
- **Buttons and forms bridge**: Button *appearance* is design; button *copy* ("Get Started" vs "Begin Your Journey" vs "Let's Go") is content. The brand identity defines both.
- **Enables the interview workflow**: t1372's style interview needs somewhere to write its output. This is that destination.

## How (Approach)

1. Create `.agents/tools/design/brand-identity.md` with YAML frontmatter (mode: subagent, tools: read, write, edit, bash, webfetch, task)
2. The brand-identity.toon template uses TOON sections for each dimension — structured enough for machine parsing, readable enough for humans
3. The agent integration instructions are directive: "Before generating UI, check `context/brand-identity.toon`. If present, all design decisions must align. Also check `context/inspiration/` for project-specific design patterns." Not optional guidance.
4. The "from scratch" workflow references t1372's interview process — doesn't duplicate it
5. The "from existing site" workflow references t1372's URL study — doesn't duplicate it
6. Include a complete example brand-identity.toon for a fictional SaaS product to show what a filled-in template looks like

Key files:
- `.agents/tools/design/brand-identity.md` — new file (primary deliverable)
- `.agents/tools/design/ui-ux-inspiration.md` — interview and URL study workflows (t1372)
- `.agents/tools/design/ui-ux-catalogue.toon` — style catalogue (t1371)
- `.agents/content/guidelines.md` — existing copywriting guidelines (relationship defined)
- `.agents/content/platform-personas.md` — channel adaptation (relationship defined)
- `.agents/content/production/image.md` — image generation (relationship defined)
- `.agents/content/production/characters.md` — character design (relationship defined)
- `.agents/content/humanise.md` — AI pattern removal (relationship defined)
- `.agents/workflows/ui-verification.md` — design quality gates (relationship defined)

## Acceptance Criteria

- [ ] File exists at `.agents/tools/design/brand-identity.md` with valid YAML frontmatter
  ```yaml
  verify:
    method: codebase
    pattern: "^---"
    path: ".agents/tools/design/brand-identity.md"
  ```
- [ ] Contains complete brand-identity.toon template covering all 8 dimensions (visual style, voice & tone, copywriting patterns, imagery, iconography, buttons & forms, media & motion, brand positioning)
  ```yaml
  verify:
    method: bash
    run: "rg -c '(visual.style|voice.*tone|copywriting|imagery|iconography|buttons.*forms|media.*motion|brand.positioning)' .agents/tools/design/brand-identity.md | awk -F: '$2 >= 8'"
  ```
- [ ] Contains agent integration instructions for design, content, and production agents
  ```yaml
  verify:
    method: codebase
    pattern: "design agent|content agent|production agent"
    path: ".agents/tools/design/brand-identity.md"
  ```
- [ ] Contains "from scratch" workflow referencing t1372's interview process
- [ ] Contains "from existing site" workflow referencing t1372's URL study
- [ ] Contains complete example brand-identity.toon for a fictional product
- [ ] Defines relationship to content/guidelines.md (default voice when no brand identity)
- [ ] Defines relationship to content/platform-personas.md (channel adaptation reads brand identity)
- [ ] Defines relationship to content/production/image.md (imagery parameters)
- [ ] Defines relationship to workflows/ui-verification.md (quality gates always apply)
- [ ] Buttons & forms section covers both visual styling AND copy patterns (CTA text, label voice, error message tone)
  ```yaml
  verify:
    method: codebase
    pattern: "(CTA|call.to.action|button.copy|error.message.tone|label.voice)"
    path: ".agents/tools/design/brand-identity.md"
  ```
- [ ] No hardcoded client-specific content
- [ ] Lint clean (markdown-formatter)

## Context & Decisions

- **Bridge, not replacement**: This doesn't replace guidelines.md or platform-personas.md. It provides the shared brand definition they both read. guidelines.md becomes the structural rules; brand-identity.toon becomes the voice.
- **TOON for per-project files**: The brand identity lives in each project repo as `context/brand-identity.toon`. TOON is structured enough for agents to parse specific dimensions without reading the whole file.
- **Copywriting patterns are first-class**: User explicitly noted that brand character comes from copywriting style. This isn't an afterthought — it's a full dimension alongside visual style.
- **Iconography included**: Icon choice (Lucide outline vs Heroicons filled vs custom) is a strong brand signal. Including it prevents the common failure of mixing icon libraries within a project.
- **Example is fictional**: The example brand-identity.toon uses a fictional SaaS product to avoid any client-specific content in the shared framework.

## Relevant Files

- `.agents/tools/design/brand-identity.md` — new file to create
- `.agents/tools/design/ui-ux-inspiration.md` — interview/URL study (t1372)
- `.agents/tools/design/ui-ux-catalogue.toon` — style catalogue (t1371)
- `.agents/content/guidelines.md` — copywriting rules (relationship)
- `.agents/content/platform-personas.md` — channel adaptation (relationship)
- `.agents/content/production/image.md` — image generation (relationship)
- `.agents/content/production/characters.md` — character design (relationship)
- `.agents/content/humanise.md` — AI pattern removal (relationship)
- `.agents/workflows/ui-verification.md:244-309` — design quality gates (relationship)
- `.agents/subagent-index.toon` — needs updating to include new design subagents

## Dependencies

- **Blocked by:** t1371 (catalogue must exist for style references), t1372 (interview workflow must exist to reference)
- **Blocks:** nothing directly (but completes the design system triad)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review all related content agents, understand current voice/tone patterns |
| Implementation | 2.5h | Write brand identity template, agent integration, workflows, example |
| Testing | 30m | Verify all cross-references resolve, example is complete, markdown lint |
| **Total** | **3.5h** | |
