<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## AI Tools for Creative

> Pricing as of early 2025 — verify on vendor sites before purchasing.

### AI Image Generation

**1. Midjourney** — Text-to-image via Discord. $10-60/month. Commercial use with paid plan. Best for: concept visualization, backgrounds, product shots, lifestyle scenes.

```text
PROMPT: [Subject] [style] [mood/lighting] [aspect ratio] [quality]
EXAMPLE: "Modern workspace with laptop, clean minimalist style, bright natural lighting --ar 16:9 --v 6"

MODIFIERS: --ar 16:9 (ratio) | --v 6 (version) | --stylize N (0-1000) | --chaos N (0-100) | --seed N (reproducible)
STYLE: "photorealistic", "8k ultra HD", "cinematic lighting", "shot on Canon 5D"

AD PATTERNS:
PRODUCT:   "Professional product photography of [product], white background, studio lighting --ar 1:1 --v 6"
LIFESTYLE: "Happy person using [product] in modern home office, natural light, documentary style --ar 4:5 --v 6"
HERO:      "Dynamic action shot of [product in use], motion blur, vibrant colors, advertising photography --ar 16:9 --v 6"
```

Workflow: /imagine → upscale (U1-U4) → variations (V1+) → download → edit.

**2. DALL-E 3** — Via ChatGPT Plus ($20/month) or Bing Image Creator (free, limited). Natural language prompts, no Discord, conversational iteration. Best for: quick concepts, illustrations, ad mockups. Workflow: describe → generate → request modifications → iterate → download.

**3. Adobe Firefly** — Free (25 credits/month), $4.99/month (100 credits), or included with Creative Cloud. Commercially safe (trained on Adobe Stock), integrated into Photoshop. Best for: generative fill, object removal, background changes. Use: select area → "Generative Fill" → describe → choose option.

**4. Stable Diffusion** — Free, open-source. Run locally (GPU required) or via DreamStudio, Playground AI, Clipdrop. Best for: unlimited generation, fine-tuned models, full control.

### AI Video Generation

**5. Runway ML** — Free tier, $12-28/month. Text-to-video, style transfer, background/object removal, green screen, slow motion. Best for: B-roll, visual effects.

**6. Synthesia / HeyGen** — AI avatar video (no filming). Script → avatar → voice → generate. Best for: explainer videos, multilingual content, product demos. Note: can look artificial; not suitable for all brands.

**7. Descript** — $12-24/month. Edit video via transcript. AI: Overdub (voice cloning), Studio Sound (noise removal), Eye Contact, filler word removal. Best for: editing UGC, fixing audio, script variations.

### AI Copywriting

**8. ChatGPT** — General-purpose ad copy.

```text
HEADLINE: "Generate 10 headline variations for [product] targeting [audience]"
BODY:     "Write Facebook ad copy for [product] using PAS framework"
HOOKS:    "Give me 20 video ad hooks for [product] that would stop the scroll"

TIPS: Be specific ("125-char Facebook headline for project management SaaS targeting marketing agencies, focusing on saving time")
      Provide context: audience, value prop, tone | Iterate: "more casual", "shorter", "add urgency"
```

**9. Jasper AI** — $49-125/month. Pre-built ad templates, brand voice, batch generation, SEO optimization.

**10. Copy.ai** — Free tier, $49/month pro. Ad copy templates, headline/CTA generators, social captions.

### AI Creative Testing

**11. AdCreative.ai** — $29-149/month. Upload product photos/URLs → AI generates variations with predicted CTR → download and test. Pre-scored creative, multiple formats, brand color integration.

**12. Pencil (TrueMedia)** — Enterprise pricing. Static and video ad generation, AI benchmarking, performance predictions. Best for: e-commerce brands scaling creative testing.

### AI Video Editing

**13. CapCut** — Free (watermark), $7.99/month. Auto captions, background removal, transitions, beat sync, templates. Best for: UGC editing, Reels/TikToks.

**14. OpusClip** — $9-19/month. Upload long video → AI identifies best moments → auto-generates captioned clips. Best for: repurposing webinars/podcasts into ads.

### AI Voice & Audio

**15. ElevenLabs** — Free tier, $5-99/month. Realistic voices, voice cloning, multilingual, emotion control. Quality nearly indistinguishable from real. Best for: voiceovers, multilingual ads.

**16. Murf AI** — $19-99/month. Similar to ElevenLabs. Best for: video narration, multilingual ads.

### AI Background & Image Editing

**17. Remove.bg** — One-click background removal. Free (low-res), $9/month (HD), API available.

**18. Photoshop AI (Generative Fill)** — Extend images for different aspect ratios, remove/add objects, change backgrounds. Keep originals; use AI for placement variations.

### AI Music & Sound

**19. Epidemic Sound** — $15-99/month. Royalty-free music library with AI search. Commercial-safe.

**20. Soundraw** — $19.99/month. AI-generated custom music. Choose mood/genre/length → customize intensity/instruments → royalty-free.

### AI Workflow: Creating a Video Ad

```text
1. Script (ChatGPT):    "Write a 45-second UGC-style video ad script for [product] targeting [audience]"
2. Voiceover (ElevenLabs): Generate VO from script
3. B-Roll (Runway ML / Pexels): Generate or source footage
4. Edit (CapCut):       Import footage + VO, auto-captions, transitions
5. Thumbnail (Midjourney): Generate eye-catching thumbnail
6. Variations:          Repeat with different scripts/voices

Time: 1-2 hours | Cost: ~$20-50 (subscriptions) | Traditional: days + $500-2000
```

### AI Limitations

**AI can't replace:** strategic thinking, brand understanding, creative judgment, performance testing, authentic UGC feel.

**AI excels at:** speed (100 variations in minutes), iteration, ideation, background removal, captions, volume.

**Best approach:** Human strategy + AI execution. Human creativity + AI production. Human editing + AI first draft.

---

## Implementation

### 30-Day Plan

| Week | Focus | Key Activities |
|------|-------|----------------|
| 1 | Audit & Setup | Analyze current creative (CPA, CTR benchmarks); competitor swipe file via Facebook Ad Library; define audiences; create brief templates |
| 2 | Production | 10+ concepts using PAS/hook frameworks; produce 20 variations: 5 image, 5 UGC video, 5 professional video, 5 carousel |
| 3 | Launch & Test | Ad sets with 5 creatives each, equal budget; monitor daily, flag early losers |
| 4 | Optimize & Scale | Review 7-day performance; iterate top 20%; pause bottom performers; scale winners; document learnings |

### Ongoing Cadence

| Cadence | Time | Activities |
|---------|------|------------|
| Daily | 15 min | Check spend/CPA, flag issues |
| Weekly | 2 hrs | Performance review, launch 2-3 new creatives, pause losers |
| Bi-weekly | 3 hrs | Fatigue audit, competitor research, test documentation |
| Monthly | Half day | Full account audit, strategic planning, next month's production |

### Production System

**Pipeline:** Brainstorm (20+ concepts/month) → Brief → Produce (multi-format) → Review/score → Launch (with tracking) → Analyze (iterate/kill/scale weekly).

**Creator network:** 5-10 UGC creators (Fiverr, Billo) + 1-2 editors + 1 designer + 1 copywriter. Template briefs, retainer relationships.

**Swipe file:** Organize by format/platform, tag by concept, note performance. Monthly review.

**Knowledge base:** Document every test result, winning formulas, failed attempts. Living doc, onboarding material.

### Resources

**Learning:** Facebook Blueprint, Google Skillshop, YouTube (Ben Heath, Charley T, Depesh Mandalia), Blogs (AdEspresso, Jon Loomer, Social Media Examiner).

**Tools:** Creative (Canva, Adobe Suite, CapCut) | AI (Midjourney, ChatGPT, ElevenLabs) | Testing (Facebook/Google Ads Manager) | Analytics (Triple Whale, Hyros, GA4).

**Communities:** Facebook Ad Buyers group, Agency Owner groups, Reddit (r/PPC, r/marketing), Twitter media buyers.

---

## Quick Reference

### Hook Formulas

```text
QUESTIONS:  "Still [pain point]?" | "Want to [outcome]?" | "What if [hypothetical]?" | "Why [surprising fact]?"
STATEMENTS: "[Result] in [timeframe]" | "Stop [bad thing]" | "I [achieved result]. Here's how." | "[Surprising stat]"
```

### Ad Copy Structure

```text
FACEBOOK/INSTAGRAM:
Hook (15 words max) → Amplify (2-3 sentences) → Proof (social proof/stat) → Offer → CTA

GOOGLE SEARCH:
H1: Keyword + differentiator | H2: Primary benefit | H3: Offer/CTA
D1: Value prop + benefits | D2: Social proof + guarantee
```

### Video Structure

```text
0-3s: HOOK (pattern interrupt) → 3-10s: PROBLEM → 10-30s: SOLUTION → 30-45s: PROOF → 45-60s: CTA
Short: 15s = Hook→Solution→CTA | 30s = Hook→Problem→Solution→CTA
```

### Platform Specs

```text
FACEBOOK:  Image 1080x1080 (1:1) 30MB | Video 1080x1920 (9:16) 4GB 1-240min | Carousel 1080x1080 2-10 cards
INSTAGRAM: Feed 1080x1080 or 1080x1350 (4:5) | Stories/Reels 1080x1920 (9:16) 15-90s
GOOGLE:    RSA 15 headlines (30 char) 4 descriptions (90 char) | Display 1200x628, 300x250, 160x600 | YouTube 16:9 1080p+
TIKTOK:    Video 1080x1920 (9:16) 15-60s
```

### Testing Priority

```text
FIRST:  1. Hook  2. Core message/value prop  3. Offer  4. Creative format
SECOND: 5. Headlines  6. Images/visuals  7. CTA  8. Social proof
THIRD:  9. Body copy variations  10. Length  11. Style elements
```

### Fatigue Indicators

```text
IMMEDIATE (act now): CTR -30%+ | CPA +25%+ | Frequency >7
WARNING:             CTR -20% | CPA +15% | Frequency 5-7 | Negative comments increasing
MONITOR:             CTR -10-15% | CPA +10% | Frequency 4-5
```

### Performance Benchmarks

```text
FACEBOOK/INSTAGRAM: CTR 1.5-3% (feed) 0.8-2% (stories) | CVR 2-5% (ecom) 5-15% (lead gen) | Frequency <4-5
GOOGLE SEARCH:      CTR 3-8%+ | CVR 5-15%
YOUTUBE:            CTR 0.5-2% | View Rate 30-40%
```
