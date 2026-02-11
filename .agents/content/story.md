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
- **Key Principle**: One story, many outputs -- design the narrative once, adapt everywhere

**Critical Rules**:

- **Hook-first always** -- Every output starts with the hook, regardless of platform
- **6-12 word constraint** on hooks -- Forces clarity and punch
- **Proven first, original second** -- 97% proven structure, 3% unique twist
- **One transformation per story** -- Before state -> struggle -> after state
- **Test 5-10 hook variants** before committing to any single angle

<!-- AI-CONTEXT-END -->

## Pre-flight Questions

Before committing to a narrative angle or hook, work through:

1. What is the theme — the universal truth this content explores?
2. What is the single takeaway — what should the audience think, feel, or do differently?
3. Does this tell a story — is there tension, transformation, and resolution?
4. Who is the protagonist — the audience, a character, or the brand — and is that the right choice?

## 7 Hook Formulas

Every piece of content starts with a hook. Use these formulas to generate variants:

| # | Formula | Example | Best For |
|---|---------|---------|----------|
| 1 | **Bold Claim** | "95% of AI influencers will fail this year" | YouTube, blog, LinkedIn |
| 2 | **Question** | "Why do most AI creators quit in 6 months?" | Social, email, podcast |
| 3 | **Story** | "I spent $10K on AI tools and here's what happened" | YouTube, podcast, blog |
| 4 | **Contrarian** | "The AI tool everyone recommends is actually terrible" | X, Reddit, short-form |
| 5 | **Result** | "How I got 1M views using only free AI tools" | YouTube, short-form, social |
| 6 | **Problem-Agitate** | "You're wasting 4 hours/day on content that nobody sees" | Email, LinkedIn, blog |
| 7 | **Curiosity Gap** | "The one AI trick that changed everything (it's not what you think)" | Short-form, X, email |

**Hook generation process**:

1. Write 10 variants using different formulas
2. Score each on: specificity (1-5), emotion (1-5), curiosity (1-5)
3. Pick top 3 for A/B testing
4. Use the winner, archive the rest for future repurposing

## 4-Part Script Framework

Universal structure that works across all formats:

### 1. Hook (first 5-10 seconds / first sentence)

- Pattern interrupt or immediate value promise
- Use one of the 7 hook formulas
- Must work standalone (visible in previews, thumbnails, subject lines)

### 2. Storytelling (60-70% of content)

- **Before state**: Where the audience is now (pain, frustration, confusion)
- **Struggle**: The journey, failed attempts, common mistakes
- **After state**: The transformation, result, insight

Frameworks for the storytelling section:

- **AIDA**: Attention -> Interest -> Desire -> Action
- **Three-Act**: Setup -> Confrontation -> Resolution
- **Hero's Journey**: Ordinary world -> Call to adventure -> Return with knowledge
- **Problem-Solution-Result**: Pain -> Method -> Proof
- **Listicle with Stakes**: "5 mistakes that cost creators $10K+"

### 3. Soft Sell (15-20% of content)

- Transition naturally from story to offer/CTA
- Frame as logical next step, not sales pitch
- Use social proof or scarcity only if genuine

### 4. Visual Cues (embedded throughout)

- B-roll directions for video
- Image suggestions for blog/social
- Tone shifts for audio/podcast
- Formatting cues for text (bold, line breaks, emoji sparingly)

## Angle Selection

Choose the story angle based on audience state and platform:

| Angle | When to Use | Platforms |
|-------|-------------|-----------|
| **Pain** | Audience is frustrated, searching for solutions | Blog, email, YouTube |
| **Aspiration** | Audience wants to level up, inspired by results | Short-form, social, YouTube |
| **Contrarian** | Audience follows conventional wisdom that's wrong | X, Reddit, podcast |
| **Educational** | Audience needs to learn a skill or concept | Blog, YouTube, podcast |
| **Hot take** | Audience is engaged in a trending conversation | X, short-form, Reddit |
| **Behind the scenes** | Audience wants authenticity and process | YouTube, podcast, social |

## Campaign Audit Process

Before publishing, validate the story package with this 7-step audit:

1. **Offer clarity** -- Can you explain the value in one sentence?
2. **Urgency** -- Is there a reason to act now (not manufactured)?
3. **Pain angle** -- Does it address a real, specific pain point?
4. **Cosmetic vs life-changing** -- Is this a nice-to-have or a must-have?
5. **Hook + visual alignment** -- Does the hook match the thumbnail/preview?
6. **4 elements present** -- Hook, story, soft sell, visual cues all included?
7. **Test readiness** -- Are there 3+ variants ready for A/B testing?

## Pattern Interrupt Principle

Hooks work by breaking the audience's scroll pattern. Three techniques:

1. **Contrast** -- Juxtapose unexpected elements ("The $0 tool that beats $500/month software")
2. **Extremes** -- Use specific, surprising numbers ("I analyzed 10,000 AI videos and found this")
3. **Unexpected combinations** -- Pair unrelated concepts ("What chess taught me about AI prompting")

## Story Package Output Format

When generating a story package, produce:

```text
# Story Package: [Topic]

## Hook Variants (scored)
1. [Hook] — Formula: [name] — Score: specificity/emotion/curiosity = total
2. ...
(minimum 5 variants)

## Narrative Arc
- Before state: [audience's current pain]
- Struggle: [common mistakes, failed approaches]
- Transformation: [the insight/method/result]
- After state: [where they'll be after consuming this content]

## Angle
- Primary: [angle name]
- Rationale: [why this angle for this audience]

## Script Skeleton (4-Part)
### Hook
[Winning hook variant]

### Story
[Scene-by-scene or section-by-section outline]

### Soft Sell
[CTA framing]

### Visual Cues
[B-roll / image / formatting directions]

## Platform Adaptation Notes
- YouTube: [specific adaptations]
- Short-form: [specific adaptations]
- Social: [specific adaptations]
- Blog: [specific adaptations]
- Email: [specific adaptations]
- Podcast: [specific adaptations]
```

## UGC Brief Storyboard

Generate a complete multi-shot storyboard from a business description. This template eliminates manual shot-by-shot prompt writing by combining the 4-Part Script Framework (above) with the 7-component video prompt format (`tools/video/video-prompt-design.md`).

### Input: Business Brief

Provide a single business description and the template generates all shots:

```text
# UGC Brief

Business:     [Company name and what they do]
Product:      [Specific product/service being featured]
Audience:     [Target customer — demographics, pain points]
Presenter:    [Character description — 15+ attributes per video-prompt-design.md]
Tone:         [warm | energetic | authoritative | casual | inspirational]
Platform:     [TikTok/Reels (9:16) | YouTube (16:9) | both]
Duration:     [15s | 30s | 60s]
CTA:          [What the viewer should do — visit site, sign up, buy, etc.]
```

### Output: 5-Shot Storyboard

The template produces a 5-shot storyboard. Each shot maps to the 4-Part Script Framework and includes all 7 components from `video-prompt-design.md`.

| Shot | Framework Role | Duration | Purpose |
|------|---------------|----------|---------|
| 1 | **Hook** | 2-3s | Pattern interrupt — bold claim or question from the 7 Hook Formulas |
| 2 | **Story: Before State** | 3-5s | Presenter shows the pain/frustration the audience knows |
| 3 | **Story: Transformation** | 5-8s | Product hero — demonstrate the solution in action |
| 4 | **Story: After State** | 3-5s | Result proof — show the outcome or transformation |
| 5 | **Soft Sell + CTA** | 2-3s | Direct call to action with presenter addressing camera |

### Per-Shot 7-Component Format

Each shot in the storyboard uses this structure (from `tools/video/video-prompt-design.md`):

```text
## Shot [N]: [FRAMEWORK_ROLE]

Subject:   [Presenter description — identical across all shots for consistency]
Action:    [Specific movements, gestures, micro-expressions for this shot]
Scene:     [Environment, props, lighting — matches business context]
Style:     [Camera: shot type, angle, movement | Colour palette | DOF]
Dialogue:  (Presenter): "[8s-rule: 12-15 words max]" (Tone: [from brief])
Sounds:    [Diegetic audio only for UGC — no score, no stock music]
Technical: [Negatives: subtitles, watermark, text overlays, amateur quality]
```

### Worked Example

**Brief**: "FreshBrew, a specialty coffee subscription. Product: monthly curated coffee box. Audience: 25-40 remote workers who drink 3+ cups/day but are bored of supermarket coffee. Presenter: Maya, a 32-year-old South Asian woman with shoulder-length dark hair, warm brown eyes, wearing a cream knit sweater, relaxed posture, genuine smile. Tone: warm. Platform: TikTok/Reels (9:16). Duration: 30s. CTA: Link in bio for first box 50% off."

---

**Shot 1: Hook** (3s) — Bold Claim formula

```text
Subject:   Maya, a 32-year-old South Asian woman with shoulder-length dark wavy
           hair, warm brown eyes, light olive skin, wearing a cream knit sweater
           over a white tee, relaxed posture, genuine warm smile, minimal gold
           stud earrings, natural makeup, confident and approachable demeanour
Action:    Holds coffee mug close to face, inhales deeply, eyes widen with
           surprise, looks directly into camera with eyebrows raised
Scene:     Modern kitchen counter, morning light from window, coffee equipment
           visible in background, warm wood tones, steam rising from mug
Style:     CU (head and shoulders), eye-level, handheld with subtle movement,
           warm colour palette (#F4E4C1, #6B4226, #FFFFFF), shallow DOF
Dialogue:  (Maya): "Your morning coffee is lying to you." (Tone: warm playfulness
           with a hint of conspiracy)
Sounds:    Coffee pouring, gentle morning kitchen ambiance, no music
Technical: subtitles, captions, watermark, text overlays, logo, amateur quality,
           distorted hands, oversaturation
```

**Shot 2: Before State** (5s) — Pain angle

```text
Subject:   [Identical Maya description]
Action:    Grimaces while sipping from a generic mug, sets it down with
           disappointment, shakes head slightly, shoulders slump
Scene:     Same kitchen, harsh overhead fluorescent light, generic supermarket
           coffee bag visible on counter, dull morning atmosphere
Style:     MS (waist up), slightly high angle (looking down = diminished),
           static shot, desaturated warm tones, medium DOF
Dialogue:  (Maya): "Same bland bag every week. Three cups a day of... nothing."
           (Tone: genuine frustration, relatable)
Sounds:    Mug clinking on counter, quiet kitchen hum, no music
Technical: subtitles, captions, watermark, text overlays, logo, amateur quality
```

**Shot 3: Transformation — Product Hero** (8s)

```text
Subject:   [Identical Maya description]
Action:    Opens FreshBrew box with visible excitement, lifts out a coffee bag,
           reads the label with curiosity, scoops beans into grinder, presses
           brew — movements are deliberate and tactile
Scene:     Same kitchen, now warm natural window light, FreshBrew branded box
           centre-frame, colourful coffee bags inside, steam rising from fresh
           pour, warm golden atmosphere
Style:     Sequence: CU on hands opening box → MS of Maya reading label → CU
           tracking shot following pour into mug, warm saturated palette
           (#F4E4C1, #6B4226, #D4A574), shallow DOF on product
Dialogue:  (Maya): "Every month, beans I'd never find myself. Single origin,
           roasted last week." (Tone: warm discovery, genuine enthusiasm)
Sounds:    Box opening, beans rustling, grinder whirring, coffee pouring,
           no music
Technical: subtitles, captions, watermark, text overlays, logo, amateur quality,
           blurry product text
```

**Shot 4: After State — Result Proof** (5s)

```text
Subject:   [Identical Maya description]
Action:    Takes first sip of new coffee, eyes close in satisfaction, opens
           eyes with a genuine smile, nods slowly, holds mug with both hands
Scene:     Same kitchen, warm morning light, laptop open in background
           suggesting remote work, cosy and elevated atmosphere
Style:     CU (face and mug), eye-level, slow dolly in (building intimacy),
           warm rich palette, shallow DOF — face sharp, background soft
Dialogue:  (Maya): "This is what three cups a day should taste like."
           (Tone: quiet satisfaction, contentment)
Sounds:    Gentle sip, quiet morning ambiance, distant birdsong, no music
Technical: subtitles, captions, watermark, text overlays, logo, amateur quality
```

**Shot 5: CTA** (3s)

```text
Subject:   [Identical Maya description]
Action:    Looks directly into camera, points down (toward link), warm
           confident smile, slight head tilt
Scene:     Same kitchen, FreshBrew box visible beside her, warm natural light,
           clean and inviting frame
Style:     MS (waist up), eye-level, static shot, warm palette, medium DOF
Dialogue:  (Maya): "Link in bio — first box is half off." (Tone: friendly
           invitation, no pressure)
Sounds:    Quiet kitchen ambiance, no music
Technical: subtitles, captions, watermark, text overlays, logo, amateur quality
```

---

### Storyboard Generation Process

1. **Fill the brief** — Business, product, audience, presenter, tone, platform, duration, CTA
2. **Select hook formula** — Pick from the 7 Hook Formulas based on audience state and platform
3. **Generate 5 shots** — Use the per-shot 7-component format above
4. **Score hooks** — Generate 5+ hook variants for Shot 1, score on specificity/emotion/curiosity
5. **Generate image frames** — Feed each shot to `content/production/image.md` UGC Brief Image Template for static keyframes
6. **Generate video** — Feed shots to video model (Sora 2 Pro for UGC, Veo 3.1 for cinematic)
7. **Assemble** — Stitch shots in editing tool, add text overlays in post (not in generation)

### Adapting Shot Count

| Duration | Shots | Adjustment |
|----------|-------|------------|
| 15s | 3 | Merge: Hook + Before State, Transformation, CTA |
| 30s | 5 | Standard template above |
| 60s | 7-8 | Split Transformation into 2-3 product demo shots, add testimonial shot |

### Integration Points

- **Hook formulas**: Shot 1 uses the 7 Hook Formulas from this document
- **4-Part Framework**: Shots map directly to Hook → Story → Soft Sell → Visual Cues
- **Video prompts**: Each shot follows `tools/video/video-prompt-design.md` 7-component format
- **Image keyframes**: Feed shots to `content/production/image.md` UGC Brief Image Template
- **Character consistency**: Presenter description stays identical across all shots per `content/production/characters.md`
- **Audio design**: UGC = all diegetic, no score per `content/production/audio.md`
- **Distribution**: Output adapts to platform specs in `content/distribution/short-form.md`

## Related

- `content/research.md` -- Feeds into story design (audience data, pain points)
- `content/production/writing.md` -- Expands story into full scripts and copy
- `content/production/image.md` -- UGC Brief Image Template for per-shot keyframes
- `content/optimization.md` -- A/B tests hook variants and story angles
- `content.md` -- Parent orchestrator (diamond pipeline)
- `tools/video/video-prompt-design.md` -- 7-component format used in each shot
- `content/production/video.md` -- Video generation (Sora 2 Pro for UGC)
- `content/production/audio.md` -- UGC audio design (diegetic only)
