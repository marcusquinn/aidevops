---
name: writing
description: Scripts, copy, captions, and text content production across all formats
mode: subagent
model: sonnet
---

# Writing - Multi-Format Text Production

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Transform story packages into platform-ready scripts, copy, and text content
- **Input**: Story package (from `content/story.md`) or direct brief
- **Output**: Long-form scripts, short-form scripts, social copy, blog drafts, email copy, captions
- **Key Principle**: Same narrative, different delivery -- adapt voice, length, and structure per format

**Critical Rules**:

- **Hook-first in every format** -- First line/sentence/second must hook
- **8-second dialogue chunks** for AI video -- Longer blocks cause unnatural pacing
- **Platform-native voice** -- No cross-posting smell (each platform has distinct expectations)
- **One CTA per piece** -- Clarity beats comprehensiveness
- **Scene-by-scene for video** -- Include B-roll directions, not just dialogue

<!-- AI-CONTEXT-END -->

## Output Formats

### Long-Form Script (YouTube, Podcast)

Target: 8-15 minutes (1,200-2,200 words spoken)

**Structure**:

```text
# [Title]

## HOOK (0:00-0:15)
[Opening line — pattern interrupt or bold claim]
[Visual: B-roll description or camera direction]

## SCENE 1: [Setup] (0:15-2:00)
[Narration — 8-second chunks max]
[Visual: B-roll / screen recording / graphic]
[Transition: bridge sentence to next scene]

## SCENE 2: [Problem/Story] (2:00-5:00)
[Narration]
[Visual: ...]

## SCENE 3: [Solution/Insight] (5:00-8:00)
[Narration]
[Visual: ...]

## SCENE 4: [Proof/Examples] (8:00-10:00)
[Narration]
[Visual: ...]

## CTA (10:00-10:30)
[Soft sell — natural transition from content]
[Visual: end screen, subscribe animation]

## END SCREEN (10:30-11:00)
[Suggested video tease]
```

**Rules**:

- Every scene has narration + visual direction
- B-roll directions are specific ("show screen recording of tool X dashboard", not "show relevant footage")
- Dialogue pacing: 8-second maximum chunks for AI voice generation
- Include timestamp estimates for each scene
- Mark emotional beats: [PAUSE], [EMPHASIS], [LOWER VOICE]

### Short-Form Script (TikTok, Reels, Shorts)

Target: 30-60 seconds (75-150 words spoken)

**Structure**:

```text
# [Hook — first 1-3 seconds]

[Setup — 5 seconds]
[Payoff — 10-15 seconds]
[Twist or reinforcement — 5 seconds]
[CTA — 3 seconds]

CAPTION: [Full text for silent viewers]
SOUND: [Mood/genre suggestion]
CUTS: [Cut timing — e.g., "cut every 1.5s"]
```

**Rules**:

- Hook must work in first 1-3 seconds (before scroll)
- Fast cuts: 1-3 seconds per shot
- Captions are mandatory (80%+ watch without sound)
- Single idea only -- no tangents
- End with loop potential (last frame connects to first)

### Social Copy

#### X (Twitter)

**Thread format**:

```text
POST 1 (HOOK): [Under 280 chars, standalone value]
POST 2: [Expand on the hook]
POST 3-7: [One point per post, each standalone]
POST 8 (CTA): [Soft ask — follow, bookmark, reply]
```

**Single post**: Under 280 chars. Front-load value. Personality-forward.

#### LinkedIn

**Post format**:

```text
[Hook line — bold or surprising]

[2-3 short paragraphs — insight, story, or data]

[Key takeaway — one sentence]

[CTA — question or invitation to discuss]

#hashtag1 #hashtag2 #hashtag3
```

Target: 1,200-1,500 characters. Professional but not corporate.

#### Reddit

**Post format**:

```text
Title: [Curiosity-driven, not clickbait]

Body:
[Context — why you're posting, what you found]
[Value — the insight, data, or resource]
[Discussion prompt — genuine question for the community]
```

Rules: No self-promotion. Value-first. Community-native tone.

### Blog Draft

**Structure**:

```text
# [H1 — Target keyword, under 60 chars]

[Intro paragraph — hook + promise + what they'll learn]

## [H2 — Section 1]
[Content — 200-400 words]

## [H2 — Section 2]
[Content — 200-400 words]

### [H3 — Subsection if needed]
[Content]

## [H2 — Section 3]
[Content]

## Key Takeaways
- [Bullet 1]
- [Bullet 2]
- [Bullet 3]

## [CTA Section]
[Natural transition to offer/next step]
```

**SEO rules**:

- Target keyword in H1, first paragraph, and 1-2 H2s
- 1,500-2,500 words for comprehensive coverage
- Internal links: 3-5 to related content
- Meta title: under 60 chars, keyword-front-loaded
- Meta description: under 155 chars, includes CTA

### Email Copy

**Newsletter format**:

```text
SUBJECT: [5 variants for A/B testing]
PREVIEW: [Under 90 chars — extends the subject line]

[Opening hook — personal, story-driven]

[Body — single narrative thread, 300-500 words]

[CTA — one clear action, button or link]

P.S. [Secondary hook or bonus value]
```

**Sequence email format**:

```text
EMAIL 1 (Day 0): Welcome + immediate value
EMAIL 2 (Day 1): Story + pain point
EMAIL 3 (Day 3): Solution + social proof
EMAIL 4 (Day 5): Offer + urgency
EMAIL 5 (Day 7): Last chance + FAQ
```

### Podcast Script

**Talking points format**:

```text
# Episode: [Title]

## INTRO (0:00-1:00)
- [Hook — why this matters today]
- [What they'll learn]
- [Sponsor read if applicable]

## SEGMENT 1: [Topic] (1:00-5:00)
- [Talking point 1]
- [Talking point 2]
- [Anecdote or example]

## SEGMENT 2: [Topic] (5:00-10:00)
- [Talking point 1]
- [Talking point 2]

## SEGMENT 3: [Topic] (10:00-15:00)
- [Talking point 1]
- [Key insight]

## OUTRO (15:00-16:00)
- [Summary — one sentence]
- [CTA — subscribe, review, share]
- [Next episode tease]

## SHOW NOTES
- [Timestamps]
- [Links mentioned]
- [Resources]
```

## Voice and Tone Adaptation

| Platform | Voice | Pacing | Formality |
|----------|-------|--------|-----------|
| YouTube | Conversational, energetic | Medium (150 wpm) | Low-medium |
| Short-form | Punchy, direct | Fast (170 wpm) | Low |
| X | Sharp, opinionated | Rapid | Low |
| LinkedIn | Thoughtful, professional | Measured | Medium-high |
| Reddit | Authentic, helpful | Natural | Low |
| Blog | Authoritative, clear | Steady | Medium |
| Email | Personal, direct | Conversational | Low-medium |
| Podcast | Warm, storytelling | Natural (140 wpm) | Low |

## Quality Checklist

Before delivering any written output:

- [ ] Hook is in the first line/sentence
- [ ] Voice matches platform expectations
- [ ] CTA is clear and singular
- [ ] No cross-posting smell (platform-native language)
- [ ] Dialogue chunks are under 8 seconds (for video)
- [ ] Captions included (for video/short-form)
- [ ] SEO elements present (for blog)
- [ ] Subject line variants included (for email)
- [ ] B-roll directions included (for video scripts)

## Related

- `content/story.md` -- Provides the narrative framework and hook variants
- `content/production/image.md` -- Visual assets referenced in scripts
- `content/production/video.md` -- Video production specs for script adaptation
- `content/production/audio.md` -- Voice pipeline for script delivery
- `content/distribution/` -- Channel-specific conventions for final adaptation
- `content.md` -- Parent orchestrator (diamond pipeline)
