---
name: story
description: Narrative design, hooks, angles, and frameworks for platform-agnostic storytelling
mode: subagent
model: sonnet
---

# Story - Narrative Design and Hook Engineering

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Input**: Research brief (`content/research.md`) or topic + audience
- **Output**: Story package — hook variants, narrative arc, transformation framework, angle selection
- **Principle**: One story, many outputs — design the narrative once, adapt everywhere
- **Hook-first always** — every output starts with the hook, regardless of platform
- **6-12 word constraint** on hooks — forces clarity and punch
- **Proven first, original second** — 97% proven structure, 3% unique twist
- **One transformation per story** — before state → struggle → after state
- **Test 5-10 hook variants** before committing to any single angle

<!-- AI-CONTEXT-END -->

## Pre-flight Checklist

1. **Theme** — universal truth explored?
2. **Takeaway** — audience thinks, feels, or does what differently?
3. **Story** — tension, transformation, resolution present?
4. **Protagonist** — audience, character, or brand?

## 7 Hook Formulas

| # | Formula | Example | Best For |
|---|---------|---------|----------|
| 1 | **Bold Claim** | "95% of AI influencers will fail this year" | YouTube, blog, LinkedIn |
| 2 | **Question** | "Why do most AI creators quit in 6 months?" | Social, email, podcast |
| 3 | **Story** | "I spent $10K on AI tools — here's what happened" | YouTube, podcast, blog |
| 4 | **Contrarian** | "The AI tool everyone recommends is terrible" | X, Reddit, short-form |
| 5 | **Result** | "How I got 1M views using only free AI tools" | YouTube, short-form, social |
| 6 | **Problem-Agitate** | "You're wasting 4h/day on content nobody sees" | Email, LinkedIn, blog |
| 7 | **Curiosity Gap** | "The one AI trick that changed everything" | Short-form, X, email |

**Hook process**: Write 10 variants → score specificity/emotion/curiosity (1-5 each) → top 3 for A/B → archive rest.

## 4-Part Script Framework

| Part | Weight | Content |
|------|--------|---------|
| **Hook** | first 5-10s | Pattern interrupt or value promise. Standalone-capable (previews, thumbnails, subject lines). |
| **Story** | 60-70% | Before state (pain) → Struggle (failed attempts) → After state (transformation) |
| **Soft Sell** | 15-20% | Natural story-to-CTA transition. Frame as next step, not pitch. |
| **Visual Cues** | throughout | B-roll directions, image suggestions, tone shifts, formatting cues |

**Story frameworks**: AIDA · Three-Act · Hero's Journey · Problem-Solution-Result · Listicle with Stakes

## Angle Selection

| Angle | When to Use | Platforms |
|-------|-------------|-----------|
| **Pain** | Audience frustrated, seeking solutions | Blog, email, YouTube |
| **Aspiration** | Audience wants to level up | Short-form, social, YouTube |
| **Contrarian** | Conventional wisdom wrong | X, Reddit, podcast |
| **Educational** | Audience needs a skill | Blog, YouTube, podcast |
| **Hot take** | Trending conversation | X, short-form, Reddit |
| **Behind the scenes** | Audience wants authenticity | YouTube, podcast, social |

## Campaign Audit (7-step)

1. **Offer clarity** — value in one sentence?
2. **Urgency** — real reason to act now?
3. **Pain angle** — specific pain addressed?
4. **Cosmetic vs life-changing** — must-have or nice-to-have?
5. **Hook + visual alignment** — hook matches thumbnail/preview?
6. **4 elements present** — hook, story, soft sell, visual cues?
7. **Test readiness** — 3+ variants for A/B?

## Pattern Interrupt Techniques

1. **Contrast** — juxtapose unexpected elements ("$0 tool that beats $500/month software")
2. **Extremes** — specific surprising numbers ("I analyzed 10,000 AI videos — found this")
3. **Unexpected combos** — pair unrelated concepts ("What chess taught me about AI prompting")

## Story Package Output

```text
# Story Package: [Topic]
## Hook Variants (scored) — min 5: [Hook] — Formula: [name] — Score: S/E/C = total
## Narrative Arc — Before / Struggle / Transformation / After
## Angle — Primary: [name] — Rationale: [why]
## Script Skeleton — Hook / Story / Soft Sell / Visual Cues
## Platform Adaptation — YouTube / Short-form / Social / Blog / Email / Podcast
```

## UGC Brief Storyboard

Multi-shot storyboard from a business brief. Uses 4-Part Script Framework + 7-component video prompt format (`tools/video/video-prompt-design.md`).

### Input Brief

```text
Business:   [Company + what they do]
Product:    [Product/service featured]
Audience:   [Target customer — demographics, pain points]
Presenter:  [Character — 15+ attributes per video-prompt-design.md]
Tone:       [warm | energetic | authoritative | casual | inspirational]
Platform:   [TikTok/Reels (9:16) | YouTube (16:9) | both]
Duration:   [15s | 30s | 60s]
CTA:        [Viewer action]
```

### 5-Shot Storyboard Structure

| Shot | Role | Duration | Purpose |
|------|------|----------|---------|
| 1 | **Hook** | 2-3s | Pattern interrupt — bold claim or question |
| 2 | **Before State** | 3-5s | Show pain/frustration |
| 3 | **Transformation** | 5-8s | Product hero — demonstrate solution |
| 4 | **After State** | 3-5s | Result proof — show outcome |
| 5 | **Soft Sell + CTA** | 2-3s | Direct CTA, presenter to camera |

### Per-Shot Format (7 components — `video-prompt-design.md`)

```text
## Shot [N]: [FRAMEWORK_ROLE]
Subject:   [Presenter — identical across shots]
Action:    [Movements, gestures, micro-expressions]
Scene:     [Environment, props, lighting]
Style:     [Camera: type, angle, movement | Palette | DOF]
Dialogue:  (Presenter): "[8s-rule: 12-15 words max]" (Tone: [from brief])
Sounds:    [Diegetic only — no score, no stock music]
Technical: [Negatives: subtitles, watermark, text overlays, amateur quality]
```

### Shot Count by Duration

| Duration | Shots | Adjustment |
|----------|-------|------------|
| 15s | 3 | Merge Hook + Before State, Transformation, CTA |
| 30s | 5 | Standard 5-shot |
| 60s | 7-8 | Split Transformation into 2-3 demo shots + testimonial |

### Generation Process

1. Fill brief → select hook formula → generate 5 shots
2. Score 5+ hook variants (Shot 1) on specificity/emotion/curiosity
3. Image keyframes → feed each shot to `content/production-image.md`
4. Video → Sora 2 Pro (UGC) or Veo 3.1 (cinematic)
5. Assemble; add text overlays in post (not in generation)

## Related

- `content.md` — parent orchestrator (diamond pipeline)
- `content/research.md` — audience data, pain points → story input
- `content/production-writing.md` — story → full scripts and copy
- `content/production-image.md` — per-shot keyframes
- `content/production-video.md` — video generation (Sora 2 Pro for UGC)
- `content/production-audio.md` — UGC audio (diegetic only)
- `content/production-characters.md` — presenter consistency
- `content/optimization.md` — A/B tests hooks and angles
- `content/distribution-short-form.md` — platform specs
- `tools/video/video-prompt-design.md` — 7-component shot format
