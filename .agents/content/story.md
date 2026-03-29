---
name: story
description: Narrative design, hooks, angles, and frameworks for platform-agnostic storytelling
mode: subagent
model: sonnet
---

# Story - Narrative Design and Hook Engineering

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Craft platform-agnostic narratives that adapt to any media format or distribution channel
- **Input**: Research brief (from `content/research.md`) or topic + audience
- **Output**: Story package: hook variants, narrative arc, transformation framework, angle selection
- **Key Principle**: One story, many outputs — design the narrative once, adapt everywhere

**Critical Rules**:

- **Hook-first always** — every output starts with the hook, regardless of platform
- **6-12 word constraint** on hooks — forces clarity and punch
- **Proven first, original second** — 97% proven structure, 3% unique twist
- **One transformation per story** — before state → struggle → after state
- **Test 5-10 hook variants** before committing to any single angle

<!-- AI-CONTEXT-END -->

## Pre-flight Checklist

1. **Theme** — universal truth this content explores?
2. **Takeaway** — what should the audience think, feel, or do differently?
3. **Story** — tension, transformation, and resolution present?
4. **Protagonist** — audience, character, or brand — right choice?

## 7 Hook Formulas

| # | Formula | Example | Best For |
|---|---------|---------|----------|
| 1 | **Bold Claim** | "95% of AI influencers will fail this year" | YouTube, blog, LinkedIn |
| 2 | **Question** | "Why do most AI creators quit in 6 months?" | Social, email, podcast |
| 3 | **Story** | "I spent $10K on AI tools and here's what happened" | YouTube, podcast, blog |
| 4 | **Contrarian** | "The AI tool everyone recommends is actually terrible" | X, Reddit, short-form |
| 5 | **Result** | "How I got 1M views using only free AI tools" | YouTube, short-form, social |
| 6 | **Problem-Agitate** | "You're wasting 4 hours/day on content that nobody sees" | Email, LinkedIn, blog |
| 7 | **Curiosity Gap** | "The one AI trick that changed everything (it's not what you think)" | Short-form, X, email |

**Hook process**: Write 10 variants → score specificity/emotion/curiosity (1-5 each) → pick top 3 for A/B → archive rest for repurposing.

## 4-Part Script Framework

| Part | Weight | Content |
|------|--------|---------|
| **Hook** | first 5-10s | Pattern interrupt or value promise. Must work standalone (previews, thumbnails, subject lines). |
| **Story** | 60-70% | Before state (pain) → Struggle (failed attempts) → After state (transformation) |
| **Soft Sell** | 15-20% | Transition naturally from story to CTA. Frame as logical next step, not pitch. |
| **Visual Cues** | throughout | B-roll directions, image suggestions, tone shifts, formatting cues |

**Story frameworks**: AIDA · Three-Act · Hero's Journey · Problem-Solution-Result · Listicle with Stakes

## Angle Selection

| Angle | When to Use | Platforms |
|-------|-------------|-----------|
| **Pain** | Audience is frustrated, searching for solutions | Blog, email, YouTube |
| **Aspiration** | Audience wants to level up | Short-form, social, YouTube |
| **Contrarian** | Conventional wisdom is wrong | X, Reddit, podcast |
| **Educational** | Audience needs to learn a skill | Blog, YouTube, podcast |
| **Hot take** | Trending conversation | X, short-form, Reddit |
| **Behind the scenes** | Audience wants authenticity | YouTube, podcast, social |

## Campaign Audit (7-step)

1. **Offer clarity** — value explainable in one sentence?
2. **Urgency** — reason to act now (not manufactured)?
3. **Pain angle** — real, specific pain point addressed?
4. **Cosmetic vs life-changing** — nice-to-have or must-have?
5. **Hook + visual alignment** — hook matches thumbnail/preview?
6. **4 elements present** — hook, story, soft sell, visual cues all included?
7. **Test readiness** — 3+ variants ready for A/B testing?

## Pattern Interrupt Techniques

1. **Contrast** — juxtapose unexpected elements ("The $0 tool that beats $500/month software")
2. **Extremes** — specific, surprising numbers ("I analyzed 10,000 AI videos and found this")
3. **Unexpected combinations** — pair unrelated concepts ("What chess taught me about AI prompting")

## Story Package Output Format

```text
# Story Package: [Topic]
## Hook Variants (scored) — min 5, format: [Hook] — Formula: [name] — Score: S/E/C = total
## Narrative Arc — Before state / Struggle / Transformation / After state
## Angle — Primary: [name] — Rationale: [why for this audience]
## Script Skeleton — Hook / Story / Soft Sell / Visual Cues
## Platform Adaptation — YouTube / Short-form / Social / Blog / Email / Podcast
```

## UGC Brief Storyboard

Multi-shot storyboard from a business description. Uses 4-Part Script Framework + 7-component video prompt format (`tools/video/video-prompt-design.md`).

### Input Brief

```text
Business:   [Company name and what they do]
Product:    [Specific product/service being featured]
Audience:   [Target customer — demographics, pain points]
Presenter:  [Character description — 15+ attributes per video-prompt-design.md]
Tone:       [warm | energetic | authoritative | casual | inspirational]
Platform:   [TikTok/Reels (9:16) | YouTube (16:9) | both]
Duration:   [15s | 30s | 60s]
CTA:        [What the viewer should do]
```

### 5-Shot Storyboard Structure

| Shot | Framework Role | Duration | Purpose |
|------|---------------|----------|---------|
| 1 | **Hook** | 2-3s | Pattern interrupt — bold claim or question |
| 2 | **Story: Before State** | 3-5s | Show the pain/frustration |
| 3 | **Story: Transformation** | 5-8s | Product hero — demonstrate solution |
| 4 | **Story: After State** | 3-5s | Result proof — show the outcome |
| 5 | **Soft Sell + CTA** | 2-3s | Direct CTA, presenter to camera |

### Per-Shot Format (7 components — `video-prompt-design.md`)

```text
## Shot [N]: [FRAMEWORK_ROLE]
Subject:   [Presenter — identical across all shots for consistency]
Action:    [Movements, gestures, micro-expressions]
Scene:     [Environment, props, lighting]
Style:     [Camera: shot type, angle, movement | Colour palette | DOF]
Dialogue:  (Presenter): "[8s-rule: 12-15 words max]" (Tone: [from brief])
Sounds:    [Diegetic audio only — no score, no stock music]
Technical: [Negatives: subtitles, watermark, text overlays, amateur quality]
```

### Shot Count by Duration

| Duration | Shots | Adjustment |
|----------|-------|------------|
| 15s | 3 | Merge: Hook + Before State, Transformation, CTA |
| 30s | 5 | Standard 5-shot template |
| 60s | 7-8 | Split Transformation into 2-3 demo shots, add testimonial |

### Generation Process

1. Fill the brief → select hook formula → generate 5 shots
2. Score 5+ hook variants for Shot 1 on specificity/emotion/curiosity
3. Generate image keyframes → feed each shot to `content/production-image.md`
4. Generate video → Sora 2 Pro (UGC) or Veo 3.1 (cinematic)
5. Assemble in editing tool; add text overlays in post (not in generation)

## Related

- `content/research.md` — feeds into story design (audience data, pain points)
- `content/production-writing.md` — expands story into full scripts and copy
- `content/production-image.md` — UGC Brief Image Template for per-shot keyframes
- `content/optimization.md` — A/B tests hook variants and story angles
- `content.md` — parent orchestrator (diamond pipeline)
- `tools/video/video-prompt-design.md` — 7-component format used in each shot
- `content/production-video.md` — video generation (Sora 2 Pro for UGC)
- `content/production-audio.md` — UGC audio design (diegetic only)
- `content/production-characters.md` — presenter consistency across shots
- `content/distribution-short-form.md` — platform specs
