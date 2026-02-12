---
name: platform-personas
description: Platform-specific content adaptations - voice, tone, structure, and best practices per channel
mode: subagent
model: haiku
---

# Platform Persona Adaptations

Adapt your core brand voice for each platform. The base voice comes from `content/guidelines.md` and project-level `context/brand-voice.md` -- this subagent defines how to shift that voice per channel.

## How to Use

1. Establish your core voice in `content/guidelines.md` or `context/brand-voice.md`
2. When writing for a specific platform, apply the adaptations below
3. The core identity stays consistent -- only delivery changes

## LinkedIn

### Voice Adaptation

- **Register**: Professional, authoritative, thought-leadership
- **Perspective**: First-person ("I" for personal brands, "We" for company pages)
- **Tone shift**: More formal than blog, less formal than whitepaper
- **Reader**: Decision-makers, peers, potential clients
- **Posting cadence**: 3-5x/week, Tuesday-Thursday mornings perform best

### Structure

| Format | Length | Best For |
|--------|--------|----------|
| **Text post** | 150-300 words | Opinions, lessons, quick insights |
| **Article** | 800-2,000 words | Deep dives, case studies |
| **Carousel** | 8-12 slides, 20-40 words each | Frameworks, step-by-step guides |
| **Document** | 5-15 pages | Reports, playbooks |

### Best Practices

- Open with a hook line (question, bold claim, or surprising stat)
- Use line breaks liberally -- one thought per line
- End with a question or clear CTA to drive engagement
- Hashtags: 3-5 relevant ones, placed at the end
- Avoid: corporate jargon, "excited to announce", empty self-promotion
- Optimal posting: Tuesday-Thursday, 8-10am local time

### Example Adaptation

**Core voice**: "We build custom timber windows that last decades."

**LinkedIn**: "Most replacement windows fail within 15 years.\n\nWe engineered ours to last 30+.\n\nHere's what makes the difference (thread):"

## Instagram

### Voice Adaptation

- **Register**: Casual, visual-first, aspirational
- **Perspective**: "We" for brands, authentic and behind-the-scenes
- **Tone shift**: Warmer, more personal than other channels
- **Reader**: Visual browsers, lifestyle-oriented audience

### Structure

| Format | Caption Length | Best For |
|--------|---------------|----------|
| **Feed post** | 50-150 words | Portfolio, finished work, tips |
| **Carousel** | 30-80 words + slide text | Tutorials, before/after, lists |
| **Story** | 1-2 sentences overlay | Daily updates, polls, BTS |
| **Reel** | 30-80 words caption | Process videos, quick tips |

### Best Practices

- Lead with the visual -- caption supports, not replaces
- First line is the hook (visible before "more" truncation)
- Use emoji sparingly as visual breaks, not decoration
- Hashtags: 5-15 relevant ones (mix niche + broad), rotate sets
- Alt text on every image (accessibility + SEO)
- Place hashtags in first comment or end of caption (test both for reach)
- Avoid: walls of text, hard-sell language, stock photo aesthetics
- Optimal posting: Monday-Friday, 11am-1pm and 7-9pm local time

### Example Adaptation

**Core voice**: "We build custom timber windows that last decades."

**Instagram**: "From raw Accoya to finished frame. Swipe to see the process. [arrow emoji]\n\nBuilt for Jersey's salt air. Built to last."

## YouTube

### Voice Adaptation

- **Register**: Educational, conversational, expert-but-approachable
- **Perspective**: Direct address ("you"), presenter-led
- **Tone shift**: More conversational than written content, explain as you go
- **Reader**: Learners, researchers, how-to seekers

### Structure

| Format | Length | Best For |
|--------|--------|----------|
| **Short** | 30-60 seconds | Quick tips, single concepts |
| **Tutorial** | 8-15 minutes | How-to, walkthroughs |
| **Deep dive** | 15-30 minutes | Case studies, comparisons |
| **Vlog** | 5-10 minutes | Behind-the-scenes, day-in-life |

### Best Practices

- Title: keyword-front, under 60 characters, curiosity or value hook
- Description: first 2 lines visible -- include keyword and value prop
- Thumbnail: high contrast, readable text, expressive face or clear subject
- Chapters: add timestamps for videos over 5 minutes
- CTA: subscribe prompt at natural break, not forced intro
- Avoid: clickbait that doesn't deliver, long intros, "don't forget to like and subscribe" as opener
- Tags: 5-10 relevant keywords (include common misspellings)

### Script Tone Guide

```text
Written: "Marine-grade coatings provide superior weather resistance."
YouTube: "So we coat these with marine-grade finish -- the same stuff
         they use on boats. And that's what stops them warping in
         the salt air."
```

## X (Twitter)

### Voice Adaptation

- **Register**: Concise, opinionated, conversational
- **Perspective**: Direct, personality-forward
- **Tone shift**: Sharpest and most direct of all platforms
- **Reader**: Fast scrollers, industry peers, news followers

### Structure

| Format | Length | Best For |
|--------|--------|----------|
| **Single post** | 1-2 sentences (under 280 chars) | Hot takes, links, announcements |
| **Thread** | 3-10 posts | Breakdowns, stories, tutorials |
| **Quote post** | 1 sentence + context | Commentary, amplification |

### Best Practices

- Front-load the value -- no preamble
- Threads: number them (1/7) or use a hook post + replies
- One idea per post
- Avoid: hashtag spam, @-mention chains, "RT if you agree"
- Optimal posting: weekdays, 9-11am and 1-3pm local time

### Example Adaptation

**Core voice**: "We build custom timber windows that last decades."

**X**: "Most window companies warranty 10 years. We warranty 30. Here's why that matters:"

## Facebook

### Voice Adaptation

- **Register**: Community-oriented, warm, local
- **Perspective**: "We" as a neighbour, not a corporation
- **Tone shift**: Most personal and community-focused
- **Reader**: Local community, existing customers, referral network

### Structure

| Format | Length | Best For |
|--------|--------|----------|
| **Post** | 40-100 words | Updates, photos, community |
| **Event** | Brief description + details | Workshops, open days |
| **Album** | 5-20 photos + captions | Project showcases |

### Best Practices

- Write like you're talking to a neighbour
- Photos of real work outperform polished graphics
- Ask questions to drive comments
- Respond to every comment
- Avoid: corporate tone, link-only posts, engagement bait
- Optimal posting: Wednesday-Friday, 1-4pm local time

## Blog / Website

### Voice Adaptation

- **Register**: Expert, thorough, SEO-aware
- **Perspective**: "We" for company, "you" for reader
- **Tone shift**: Most detailed and structured of all channels
- **Reader**: Search visitors, researchers, potential customers

### Structure

See `content/guidelines.md` for full blog formatting standards. See `tools/social-media/bird.md` for X/Twitter API integration and `tools/social-media/linkedin.md` for LinkedIn automation. Key differences from social:

- Longer form (1,500-3,000 words for pillar content)
- H2/H3 hierarchy for scannability
- Internal links (3-5 per article)
- Meta title and description optimised for search (150-160 chars, include primary keyword)
- One sentence per paragraph (per guidelines.md)
- Structured data: Article schema, FAQ schema where applicable, breadcrumbs
- SEO: Primary keyword in title + H1 + first 100 words + meta. Secondary keywords in H2s. Image alt text with keywords. URL slug under 60 chars.

## Adapting Your Core Voice

### The Adaptation Framework

When writing for any platform, apply this checklist:

1. **Start with core voice** from `guidelines.md` or `context/brand-voice.md`
2. **Adjust register** (formal <-> casual) per platform table above
3. **Adjust length** to platform norms
4. **Adjust structure** (visual-first, text-first, video script)
5. **Keep identity consistent** -- same values, different delivery

### What Stays Constant

- Brand values and positioning
- Key messages and differentiators
- Spelling conventions (British English if set in guidelines)
- Honesty and authenticity
- Expertise and authority

### What Changes

- Sentence length and complexity
- Formality level
- Use of emoji and hashtags
- Content structure and formatting
- Call-to-action style
- Level of detail

## Cross-Platform Content Repurposing

One piece of content can feed multiple platforms:

```text
Blog post (2,000 words)
  -> LinkedIn article (800 words, key insights)
  -> LinkedIn carousel (8 slides, framework extract)
  -> Instagram carousel (before/after or tips)
  -> X thread (5 posts, main takeaways)
  -> YouTube script (10 min tutorial version)
  -> Facebook post (community angle + link)
```

Use `content/seo-writer.md` for the blog original, then adapt using the platform guidelines above.
