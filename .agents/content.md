---
name: content
description: Multi-media multi-channel content production pipeline - research to distribution
mode: subagent
model: opus
subagents:
  # Research & Strategy
  - research
  - story
  # Production (multi-media)
  - production/writing
  - production/image
  - production/video
  - production/audio
  - production/characters
  # Distribution (multi-channel)
  - distribution/youtube
  - distribution/short-form
  - distribution/social
  - distribution/blog
  - distribution/email
  - distribution/podcast
  # Optimization
  - optimization
  # Legacy content tools
  - guidelines
  - platform-personas
  - humanise
  - seo-writer
  - meta-creator
  - editor
  - internal-linker
  - context-templates
  # Built-in
  - general
  - explore
---

# Content - Multi-Media Multi-Channel Production Pipeline

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Multi-media multi-channel content production at scale
- **Architecture**: Diamond pipeline (Research → Story → Production fan-out → Distribution fan-out)
- **Multiplier**: One researched story → 10+ outputs across media types and channels

**The Diamond Pipeline**:

```text
                    Research
                       ↓
                     Story
                    /  |  \
                   /   |   \
            Production (multi-media)
           /    |    |    |    \
       Writing Image Video Audio Characters
          \    |    |    |    /
           \   |    |    |   /
        Distribution (multi-channel)
       /   |   |   |   |   |   \
   YouTube Short Social Blog Email Podcast
```

**Core Insight**: The highest-leverage content operation is **one story → many outputs**. Research once, craft the narrative once, then fan out to multiple media formats, then fan out again to multiple distribution channels. This is the multi-media multiplier.

**Pipeline Stages**:

1. **Research** (`content/research.md`) - Audience intel, niche validation, competitor analysis
2. **Story** (`content/story.md`) - Narrative design, hooks, angles, frameworks
3. **Production** (`content/production/`) - Multi-media asset creation
   - `writing.md` - Scripts, copy, captions
   - `image.md` - AI image gen, thumbnails, style libraries
   - `video.md` - Sora 2, Veo 3.1, Higgsfield, seed bracketing
   - `audio.md` - Voice pipeline, sound design, emotional cues
   - `characters.md` - Facial engineering, character bibles, personas
4. **Distribution** (`content/distribution/`) - Multi-channel publishing
   - `youtube/` - Long-form YouTube (migrated from root `.agents/youtube/`)
   - `short-form.md` - TikTok, Reels, Shorts (9:16, 1-3s cuts)
   - `social.md` - X, LinkedIn, Reddit (platform-native tone)
   - `blog.md` - SEO-optimized articles (references `seo/`)
   - `email.md` - Newsletters, sequences
   - `podcast.md` - Audio-first distribution
5. **Optimization** (`content/optimization.md`) - A/B testing, variant generation, analytics loops

**Invocation Examples**:

```bash
# Full pipeline: research → story → multi-channel fan-out
"Research the AI video generation niche, craft a story about why 95% of creators fail, then generate YouTube script + Short + blog outline + X thread"

# Research only
"Use content/research.md to validate the AI automation niche using the 11-Dimension Reddit Research Framework"

# Story design
"Use content/story.md to craft 10 hook variants for 'Why most AI influencers fail' using the 7 hook formulas"

# Production (single media)
"Use content/production/video.md to generate a 30s Sora 2 Pro UGC-style video with seed bracketing"

# Distribution (single channel)
"Use content/distribution/youtube/ to optimize this video for YouTube: title, description, tags, thumbnail A/B variants"

# Optimization
"Use content/optimization.md to A/B test 10 thumbnail variants and analyze retention by scene"
```

**Key Frameworks** (details in subagents):

- **11-Dimension Reddit Research** (research.md) - Sentiment, UX, competitors, pricing, use cases, support, performance, updates, power tips, red flags, decision summary
- **30-Minute Expert Method** (research.md) - Reddit scraping → NotebookLM → audience insights
- **Niche Viability Formula** (research.md) - Demand + Buying Intent + Low Competition
- **7 Hook Formulas** (story.md) - Bold Claim, Question, Story, Contrarian, Result, Problem-Agitate, Curiosity Gap
- **4-Part Script Framework** (story.md) - Hook/Storytelling/Soft Sell/Visual Cues
- **Sora 2 Pro 6-Section Template** (production/video.md) - Header, shot breakdown, timestamped actions, dialogue, sound, specs
- **Veo 3.1 Ingredients-to-Video** (production/video.md) - Upload face/product as ingredients (NOT frame-to-video)
- **Seed Bracketing** (production/video.md, optimization.md) - Test seeds 1000-1010, score, iterate (15% → 70%+ success rate)
- **Voice Pipeline** (production/audio.md) - CapCut cleanup FIRST, THEN ElevenLabs transformation
- **Facial Engineering** (production/characters.md) - Exhaustive facial analysis for cross-output consistency
- **A/B Testing Discipline** (optimization.md) - 10 variants minimum, 250-sample rule, <2% kill, >3% scale

**Model Routing** (production tasks):

- **Image generation**: Nanobanana Pro (JSON), Midjourney (objects/environments), Freepik (characters), Seedream 4 (4K refinement)
- **Video generation**: Sora 2 Pro (UGC/<10k production value), Veo 3.1 (cinematic/>100k production value)
- **Voice**: CapCut AI cleanup → ElevenLabs transformation (NEVER direct from AI output)

**Monetization Strategy** (optimization.md):

1. Affiliates first (market research phase)
2. Info products ($5-27 cold traffic)
3. Upsell ladder
4. Q4 seasonality awareness for buying intent

**Migration Note**: YouTube agents moved from `.agents/youtube/` to `.agents/content/distribution/youtube/` as of t199.8. YouTube is a distribution channel, not a main agent. Root `.agents/` is reserved for main domain agents only.

<!-- AI-CONTEXT-END -->

## Fan-Out Orchestration (t206)

The `content-fanout-helper.sh` script automates the diamond pipeline from brief to channel-specific outputs.

**Quick start**:

```bash
# 1. Generate a story brief template
content-fanout-helper.sh template default

# 2. Edit the brief with your topic, audience, and channels
# 3. Generate a fan-out plan
content-fanout-helper.sh plan ~/my-story-brief.md

# 4. Execute the plan (generates channel-specific prompts)
content-fanout-helper.sh run <plan-file>

# 5. Process each channel's prompt with AI
# Each channel directory contains a prompt.md ready for AI processing
```

**Commands**:

| Command | Purpose |
|---------|---------|
| `plan <brief>` | Generate fan-out plan from story brief |
| `run <plan>` | Execute plan, create channel-specific prompts |
| `channels` | List available distribution channels (8 channels) |
| `formats` | List media formats and channel requirements |
| `status <plan>` | Show progress of a fan-out run |
| `template [type]` | Generate brief template (default, video, blog, social) |
| `estimate <brief>` | Estimate time and token cost |

**Available channels**: youtube, short-form, social-x, social-linkedin, social-reddit, blog, email, podcast

**Brief format** (simple key: value):

```text
topic: Why 95% of AI influencers fail
angle: contrarian
audience: aspiring AI content creators
channels: youtube, short-form, social-x, social-linkedin, blog, email
tone: direct, data-backed, slightly provocative
cta: Subscribe for weekly AI creator breakdowns
notes: Include specific failure stats, name no names
```

**Pipeline flow**: Brief -> Plan -> Run -> AI Processing -> 10+ Outputs

## The Multi-Media Multiplier

The core insight: **one story → 10+ outputs**.

Traditional content creation is linear: research → write → publish. This pipeline is multiplicative:

1. **Research once** - Validate niche, understand audience pain points, analyze competitors
2. **Craft story once** - Design narrative, hooks, angles that work across formats
3. **Fan out to media** - Adapt story to writing, images, video, audio, characters
4. **Fan out to channels** - Adapt media to YouTube, Shorts, social, blog, email, podcast

**Example**: "Why 95% of AI influencers fail"

- **Research** (1h) - Reddit scraping, competitor analysis, pain point extraction
- **Story** (30m) - Hook variants, narrative arc, transformation framework
- **Production** (2h) - Long-form script, 10 thumbnail variants, 30s Short, voice clone, character cameo
- **Distribution** (1h) - YouTube video, YouTube Short, blog post, X thread, LinkedIn article, Reddit post, newsletter, carousel brief

**Total**: 4.5 hours → 8+ outputs across 6+ channels. Without the pipeline: 8 separate research cycles = 32+ hours.

## Research Phase

**Primary**: `content/research.md`

**Frameworks**:

1. **11-Dimension Reddit Research** - Comprehensive niche analysis via Perplexity mega-prompt
2. **30-Minute Expert Method** - Bulk transcript ingestion → NotebookLM → audience insights
3. **Niche Viability Formula** - Demand + Buying Intent + Low Competition (Whop/Google Trends validation)
4. **Creator Brain Clone** - Competitor transcript corpus as competitive intel (references t201)
5. **Gemini 3 Video Reverse-Engineering** - Feed competitor videos, extract reproducible prompts
6. **Pain Point Extraction** - Exact audience language, failed solutions, purchase triggers

**Supporting Tools**:

- `tools/context/context7.md` - Documentation lookup
- `tools/browser/crawl4ai.md` - Web content extraction
- `seo/google-search-console.md` - Performance data
- `seo/dataforseo.md` - Keyword volume and difficulty
- `youtube/channel-intel.md` - Competitor channel analysis
- `youtube/topic-research.md` - Topic validation

## Story Phase

**Primary**: `content/story.md`

**Frameworks**:

1. **7 Hook Formulas** - Bold Claim, Question, Story, Contrarian, Result, Problem-Agitate, Curiosity Gap (6-12 word constraint)
2. **4-Part Script Framework** - Hook/Storytelling/Soft Sell/Visual Cues
3. **Before/During/After Transformation Arc**
4. **Campaign Audit Process** - 7-step validation (offer, urgency, pain angle, cosmetic vs life-changing, hook+visual, 4 elements, test)
5. **Pain vs Aspiration Angle Selection**
6. **Pattern Interrupt Principle** - Contrast, extremes, unexpected combinations
7. **Storytelling Frameworks** - AIDA, Three-Act, Hero's Journey, Problem-Solution-Result, Listicle with Stakes
8. **"Proven First, Original Second"** - 3% twist rule

**Output**: Platform-agnostic narrative that adapts to any media or channel.

## Production Phase (Multi-Media)

**Purpose**: Transform story into media assets.

### Writing (`content/production/writing.md`)

- Long-form scripts (scene-by-scene with B-roll directions)
- Short-form scripts (hook-first, 60s constraint)
- Blog post SEO structure (references `seo/`)
- Social media copy per platform (X thread, LinkedIn article, Reddit native)
- Caption/subtitle optimization
- Dialogue pacing rules (8-second chunks for AI video)

### Image (`content/production/image.md`)

- **Nanobanana Pro JSON** - 4 template variants (editorial, environmental, magazine cover, street photography)
- **Style Library System** - Save working JSON as named templates, reuse with subject/concept swap
- **Annotated Frame-to-Video** - Generate image → annotate with arrows/labels/motion → feed to video model
- **Shotdeck Reference Library** - Find cinematic reference → Gemini reverse-engineer → prompt
- **Tool Routing** - Nanobanana Pro (JSON), Midjourney (objects/environments), Freepik (characters), Seedream 4 (4K refinement), Ideogram (face swap)
- **Thumbnail Factory Pattern** - Style template + topic concept = consistent thumbnails at scale

### Video (`content/production/video.md`)

- **Sora 2 Pro 6-Section Master Template** - Header (7-param style), shot breakdown (5-point cinematography spec), timestamped actions (0.5s intervals), dialogue, sound, specs
- **Veo 3.1 Ingredients-to-Video** - Upload face/product as ingredients (NOT frame-to-video which produces grainy yellow output)
- **Model Routing Decision Tree** - Sora 2 for UGC/authentic/<10k production value, Veo 3.1 for cinematic/character-consistent/>100k production value
- **Seed Bracketing** - Test seeds 1000-1010, score on composition/quality/style, pick winners, iterate (references t202)
- **Content-Type Seed Ranges** - People 1000-1999, action 2000-2999, landscape 3000-3999, product 4000-4999, YouTube 2000-3000
- **8K Camera Model Prompting** - Append RED Komodo 6K / ARRI Alexa LF / Sony Venice 8K
- **2-Track Production** - Objects/environments via Midjourney→VEO vs characters via Freepik→Seedream→VEO
- **Content Type Presets** - UGC 9:16 1-3s cuts, Commercial 2-5s, Cinematic 4-10s, Documentary 5-15s
- **Post-Production** - Topaz upscale 1.25-1.75x max, add film grain, 60fps for action only

**References**: `tools/video/higgsfield.md`, `tools/video/video-prompt-design.md`, t200 Veo Meta Framework

### Audio (`content/production/audio.md`)

- **Voice Pipeline** - CapCut AI voice cleanup FIRST (normalize accents/artifacts), THEN ElevenLabs transformation (NEVER direct from AI output - references t204)
- **Emotional Block Cues** - Per-word emotion tagging for natural AI speech delivery
- **4-Layer Audio Design** - Dialogue, ambient noise, SFX, music
- **LUFS Levels** - Dialogue -15, ambient -25
- **Platform Audio Rules** - UGC = all diegetic, commercial = mixed diegetic + score
- **Voice Cloning** - Consistent channel narration

**References**: `tools/voice/speech-to-speech.md`, `voice-helper.sh`

### Characters (`content/production/characters.md`)

- **Facial Engineering Framework** - Exhaustive facial analysis (bone structure, skin texture, eye details, hair, expressions) for consistency across 100+ outputs
- **Character Bible Template** - Face, personality, speaking style, wardrobe, backstory, catchphrases
- **Character Context Profile** - Personality traits, communication style, expertise areas, emotional range
- **Sora 2 Cameos** - Generate on white BG, create character, reuse across videos
- **Veo 3.1 Ingredients** - Upload face as ingredient for cross-scene consistency
- **Nanobanana Character JSON** - Save subject details as reusable template
- **Brand Identity Consistency** - Color palette, lighting, post-processing as constants
- **Model Recency Arbitrage** - Always use latest-gen model (older outputs get recognized as AI faster)

## Distribution Phase (Multi-Channel)

**Purpose**: Adapt media assets to platform-specific formats and conventions.

### YouTube (`content/distribution/youtube/`)

**Migrated from** `.agents/youtube/` (as of t199.8).

**Subagents**:

- `channel-intel.md` - Competitor analysis
- `topic-research.md` - Topic validation
- `script-writer.md` - Long-form scripts
- `optimizer.md` - Title, description, tags, thumbnails
- `pipeline.md` - End-to-end automation

**References**: `youtube-helper.sh` (YouTube Data API v3 wrapper)

### Short-Form (`content/distribution/short-form.md`)

**Platforms**: TikTok, Reels, Shorts

**Format**: 9:16, 1-3s cuts, hook-first, 60s max

**Pacing**: Fast cuts, trending sound pairing, platform-specific trends

### Social (`content/distribution/social.md`)

**Platforms**: X (Twitter), LinkedIn, Reddit

**Tone Adaptation**:

- **X** - Concise, punchy, thread-friendly
- **LinkedIn** - Professional, thought leadership
- **Reddit** - Community-native, anti-promotional

**References**: `tools/social-media/bird.md` (X), `tools/social-media/linkedin.md`, `tools/social-media/reddit.md`

### Blog (`content/distribution/blog.md`)

**SEO-Optimized Articles**

**References**: `seo/` (keyword research, on-page optimization, content analysis)

**Legacy Tools**:

- `content/seo-writer.md` - SEO-optimized writing
- `content/editor.md` - Human voice transformation
- `content/humanise.md` - Remove AI patterns
- `content/meta-creator.md` - Meta titles/descriptions
- `content/internal-linker.md` - Strategic internal linking

### Email (`content/distribution/email.md`)

**Newsletter Structure**, **Sequence Design**

**References**: `marketing.md` (FluentCRM integration)

### Podcast (`content/distribution/podcast.md`)

**Audio-First Distribution**, **Show Notes Generation**

## Optimization Phase

**Primary**: `content/optimization.md`

**Frameworks**:

1. **A/B Testing Discipline** - 10 variants minimum, 250-sample rule, below 2% = kill, above 2% = scale, above 3% = go aggressive
2. **Hook Variant Generation** - 5-10 per topic before committing
3. **Seed Bracketing as Optimization** - References t202
4. **Slide/Scene-Level Retention Analysis** - Which specific moments retain vs cause drop-off
5. **"Proven First, Original Second" Iteration Strategy**
6. **Rapid Testing Framework** - B-roll + voice clone + script variants for fastest iteration
7. **Platform-Specific Metrics** - YouTube: CTR, retention, watch time; TikTok: completion rate, shares; Blog: time on page, scroll depth
8. **Content Calendar & Cadence Engine** - SQLite-backed calendar with posting cadence tracking, gap analysis, and lifecycle management (`content-calendar-helper.sh`)
9. **Analytics Feedback Loop** - What worked → inform next research cycle

**Related Tasks**:

- t202 - Seed bracketing automation
- t207 - Thumbnail A/B testing pipeline
- t208 - Content calendar and posting cadence engine

## Legacy Content Tools

**Note**: These tools predate the multi-media pipeline architecture and focus on text-based content creation. They remain available for blog/article workflows but are superseded by the production/ and distribution/ structure for multi-media content.

**Available**:

- `content/guidelines.md` - Content standards and style guide
- `content/platform-personas.md` - Platform-specific voice adaptations
- `content/humanise.md` - Remove AI writing patterns
- `content/seo-writer.md` - SEO-optimized content writing
- `content/meta-creator.md` - Meta titles and descriptions
- `content/editor.md` - Transform AI content into human-sounding articles
- `content/internal-linker.md` - Strategic internal linking
- `content/context-templates.md` - Per-project SEO context templates

**Content Analysis Script**:

```bash
# Full content analysis with keyword
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze article.md --keyword "target keyword"

# Individual analyses
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md --keyword "keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py intent "search query"
```

## Related Tasks

- **t200** - Veo 3 Meta Framework skill import
- **t201** - Transcript corpus ingestion for competitive intel
- **t202** - Seed bracketing automation
- **t203** - AI video generation API helpers (Sora 2 / Veo 3.1 / Nanobanana Pro)
- **t204** - Voice pipeline helper (CapCut cleanup + ElevenLabs transformation)
- **t206** - Multi-channel content fan-out orchestration (one story to 10+ outputs)
- **t207** - Thumbnail A/B testing pipeline
- **t208** - Content calendar and posting cadence engine
- **t209** - YouTube slash commands (/youtube setup, /youtube research, /youtube script)
