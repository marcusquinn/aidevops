---
name: research
description: Audience research, niche validation, and competitor analysis for content strategy
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Content Research

Pre-writing research to validate niches, understand audiences, and analyse competitors before committing to content production.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Audience research, niche validation, competitor content analysis
- **Input**: Topic, niche, or URL(s) to analyse
- **Output**: Research brief with audience profile, niche viability score, competitor gaps
- **Related**: `content/seo-writer.md` (uses research output), `content/context-templates.md` (stores findings), `tools/content/content-calendar.md` (prioritises topics)

<!-- AI-CONTEXT-END -->

## Pre-flight Questions

Before generating audience or market research, work through:

1. What are the first principles here — what is actually true vs commonly assumed?
2. What is the root cause, not the symptom?
3. What biases could be distorting this — confirmation, anchoring, availability, survivorship?
4. What is the evidence — and how reliable is the source?
5. Are there physics, psychology, or reliability constraints that limit what's possible?
6. What would disprove this conclusion?

## Workflow

### 1. Audience Research

Identify who you are writing for before writing anything.

**Data sources** (in priority order):

1. **Reddit Deep Research** -- 11-Dimension Framework (see below)
2. **Google Search Console** (`seo/google-search-console.md`) -- existing query data reveals what your audience already searches for
3. **Competitor audiences** -- analyse who engages with competitor content (comments, shares, forums)
4. **Creator Brain Clone** -- bulk transcript ingestion for competitive intel (see section below, references t201)
5. **Cross-platform signals** -- TikTok/X/IG/Reddit for format migration patterns (see section below)
6. **Web search** -- use `websearch` or `webfetch` for industry reports, surveys, forum threads
7. **DataForSEO** (`seo/dataforseo.md`) -- keyword volume and demographics data

#### 11-Dimension Reddit Research Framework

The most comprehensive audience research method. Use Perplexity (or similar AI search) with this mega-prompt template to extract deep insights from Reddit discussions.

**Perplexity Mega-Prompt Template**:

```text
Analyze Reddit discussions about [TOPIC/PRODUCT/NICHE] across all relevant subreddits. Provide a comprehensive report covering these 11 dimensions:

1. SENTIMENT ANALYSIS
   - Overall sentiment (positive/negative/mixed)
   - Common praise points (what users love)
   - Common complaints (what users hate)
   - Emotional tone (frustrated, excited, skeptical, etc.)

2. USER EXPERIENCE PATTERNS
   - Typical user journey (how they discover, evaluate, adopt)
   - Learning curve feedback (easy vs difficult)
   - Common use cases (what they actually use it for)
   - Workflow integration (how it fits into their daily routine)

3. COMPETITOR COMPARISONS
   - Which alternatives are mentioned most
   - Head-to-head comparisons (X vs Y discussions)
   - Migration patterns (switching from/to other solutions)
   - Feature gaps vs competitors

4. PRICING & VALUE PERCEPTION
   - Price sensitivity (too expensive, worth it, cheap)
   - Pricing tier preferences (free, basic, pro)
   - ROI discussions (is it worth the cost)
   - Deal-seeking behavior (waiting for sales, using trials)

5. USE CASES & APPLICATIONS
   - Primary use cases (most common applications)
   - Creative/unexpected uses (edge cases)
   - Industry-specific applications
   - Beginner vs advanced use patterns

6. SUPPORT & COMMUNITY
   - Support quality feedback (responsive, helpful, slow)
   - Community helpfulness (peer support)
   - Documentation quality (clear, lacking, outdated)
   - Onboarding experience

7. PERFORMANCE & RELIABILITY
   - Speed/performance feedback
   - Reliability issues (bugs, crashes, downtime)
   - Scalability discussions (works at small/large scale)
   - Technical limitations

8. UPDATES & DEVELOPMENT
   - Feature request patterns (most wanted features)
   - Update frequency perception (too fast, too slow, just right)
   - Breaking changes complaints
   - Roadmap transparency

9. POWER USER TIPS
   - Advanced techniques shared
   - Workflow optimizations
   - Hidden features discovered
   - Integration hacks

10. RED FLAGS & DEAL-BREAKERS
    - Reasons people quit/don't adopt
    - Unresolved pain points
    - Trust/security concerns
    - Lock-in fears

11. DECISION SUMMARY
    - Who should use this (ideal customer profile)
    - Who should avoid this (poor fit profile)
    - Key decision factors (what matters most)
    - Alternatives to consider

For each dimension, provide:
- Direct quotes (exact user language)
- Frequency indicators (common, occasional, rare)
- Subreddit sources (where this feedback appears)
- Recency (recent vs historical patterns)

Focus on EXACT user language — their words, not marketing speak.
```

**Usage**:

1. Replace `[TOPIC/PRODUCT/NICHE]` with your research target
2. Run in Perplexity Pro (or Claude with web search)
3. Extract insights into audience profile template below
4. Store raw output in `context/reddit-research-[topic].md`

**Why this works**: Reddit users speak candidly about real problems, failed solutions, and purchase triggers. This is the highest-signal audience research source.

#### 30-Minute Expert Method

Become an instant expert in any niche using Reddit + NotebookLM.

**Workflow**:

1. **Reddit Scraping** (10 minutes)
   - Identify 3-5 relevant subreddits for your niche
   - Search for: "best [topic]", "vs", "alternative to", "frustrated with", "how to"
   - Collect top 20-30 threads (sort by: top, controversial, recent)
   - Copy thread URLs or use Reddit API/scraper

2. **NotebookLM Ingestion** (5 minutes)
   - Create new NotebookLM project: `[Niche] Research - [Date]`
   - Upload Reddit threads as sources (paste URLs or text)
   - Add competitor websites, product pages, documentation
   - Add any existing research docs

3. **AI-Powered Analysis** (15 minutes)
   - Ask NotebookLM: "What are the top 10 pain points discussed?"
   - Ask: "What solutions have people tried and failed with?"
   - Ask: "What language do users use to describe their problems?"
   - Ask: "What are the common objections to existing solutions?"
   - Ask: "Who is the ideal customer based on these discussions?"
   - Generate briefing doc or audio overview

**Output**: Audience insights document with:
- Pain points in exact user language
- Failed solutions (what NOT to recommend)
- Purchase triggers (what moves them to buy)
- Objection patterns (what holds them back)
- Ideal customer profile

**Storage**: Save NotebookLM briefing to `context/expert-brief-[niche].md`

**Why this works**: You're learning from hundreds of real conversations in 30 minutes. NotebookLM synthesizes patterns you'd miss reading manually.

#### Pain Point Extraction Methodology

Extract pain points in the EXACT language your audience uses (critical for hooks, copy, and resonance).

**Sources** (in priority order):

1. **Reddit threads** -- "frustrated with", "problem with", "why does", "hate that"
2. **Forum complaints** -- Quora, niche forums, Facebook groups
3. **Product reviews** -- Amazon, G2, Capterra (1-3 star reviews)
4. **Support tickets** -- if you have access to competitor support data
5. **YouTube comments** -- on competitor videos, tutorial videos
6. **Social media** -- X rants, LinkedIn frustration posts

**Extraction template**:

```markdown
## Pain Point: [Short Label]

**Exact Quote**: "[User's exact words]"
**Source**: [Platform + URL]
**Frequency**: [Common / Occasional / Rare]
**Severity**: [Deal-breaker / Major annoyance / Minor friction]

**Failed Solutions Tried**:
- [What they tried that didn't work]
- [Why it failed]

**Desired Outcome**:
- [What they wish existed]
- [How they'd know it's solved]

**Purchase Trigger**:
- [What would make them buy a solution NOW]
```

**Analysis**:

After collecting 20-30 pain points:

1. **Cluster by theme** -- group similar pain points
2. **Rank by frequency + severity** -- which appear most + matter most
3. **Identify language patterns** -- exact phrases that resonate
4. **Map to content opportunities** -- which pain points can you address

**Storage**: `context/pain-points-[niche].md`

**Usage in content**:

- **Hooks**: Lead with the pain in their words ("Tired of [exact pain]?")
- **Body**: Acknowledge failed solutions they've tried
- **CTA**: Position your solution as addressing the specific trigger

**Why this works**: Using their exact language creates instant resonance. They feel understood because you're literally speaking their words back to them.

#### Creator Brain Clone Pattern

Bulk ingest competitor channel transcripts to build a queryable competitive intelligence knowledge base.

**Workflow** (references t201 for automation):

1. **Identify target creators** (3-10 competitors in your niche)
2. **Bulk download transcripts**:

   ```bash
   # Using yt-dlp-helper.sh (see youtube/channel-intel.md)
   yt-dlp-helper.sh transcripts @channelhandle --limit 50
   # Or: yt-dlp --write-auto-sub --skip-download [channel-url]
   ```

3. **Store in memory with namespace**:

   ```bash
   # Ingest all transcripts into memory (see memory/README.md)
   memory-helper.sh store --namespace youtube-[niche] --file transcripts/*.txt --auto
   ```

4. **Query for insights**:

   ```bash
   # What topics do they cover most?
   memory-helper.sh recall --namespace youtube-[niche] "most common topics"

   # What hooks do they use?
   memory-helper.sh recall --namespace youtube-[niche] "video opening hooks"

   # What pain points do they address?
   memory-helper.sh recall --namespace youtube-[niche] "audience problems"
   ```

**What you learn**:

- **Topic coverage** -- what they talk about (and what they don't)
- **Hook patterns** -- how they open videos
- **Storytelling frameworks** -- narrative structures they use
- **Pain points addressed** -- audience problems they solve
- **Language patterns** -- exact phrases and terminology
- **Content gaps** -- topics they miss or cover poorly

**Storage**: Memory namespace `youtube-[niche]` + summary in `context/creator-intel-[niche].md`

**Why this works**: Transcript corpus is the highest-leverage competitive intel. You're analyzing hundreds of hours of content in minutes. See t201 for automation.

#### Gemini 3 Video Reverse-Engineering

Feed competitor videos to Gemini 3 to extract reproducible prompts for your own video generation.

**Workflow**:

1. **Identify high-performing competitor videos**
   - Top videos by views in your niche
   - Viral short-form content (TikTok, Reels, Shorts)
   - Ads that are running long-term (= working)

2. **Upload to Gemini 3** (supports video input):

   ```text
   Analyze this video and provide:

   1. VISUAL STYLE
      - Camera angles and movements
      - Lighting setup (natural, studio, dramatic)
      - Color grading (warm, cool, high contrast, desaturated)
      - Composition rules used

   2. SCENE BREAKDOWN
      - Shot-by-shot description with timestamps
      - B-roll elements and when they appear
      - Text overlays and graphics
      - Transitions used

   3. AUDIO DESIGN
      - Voice style (energetic, calm, authoritative)
      - Background music genre and energy level
      - Sound effects used
      - Audio mixing (voice vs music balance)

   4. PACING & EDITING
      - Average shot length
      - Cut frequency (fast cuts vs slow)
      - Retention hooks (pattern interrupts)

   5. REPRODUCIBLE PROMPT
      Generate a Sora 2 / Veo 3.1 prompt that would recreate this style:
      [Provide full structured prompt]
   ```

3. **Extract prompt template**:
   - Save the "Reproducible Prompt" output
   - Test with your own subject/topic
   - Iterate based on results

4. **Build style library**:
   - Store working prompts in `context/video-styles/[style-name].md`
   - Tag by: niche, format (long/short), production value, emotion

**Storage**: `context/video-styles/` directory with one file per style

**Why this works**: You're reverse-engineering what's already proven to work. Gemini 3 can "see" the video and translate visual style into text prompts for AI video generation.

**Related**: See `content/production/video.md` for Sora 2 / Veo 3.1 prompt frameworks, `tools/video/video-prompt-design.md` for general video prompting.

#### Cross-Platform Research Framework

Identify format migration signals and platform-specific opportunities.

**Platforms to monitor**:

| Platform | Research Focus | Tools |
|----------|---------------|-------|
| **Reddit** | Pain points, product discussions, buying intent | Perplexity, manual search |
| **TikTok** | Trending formats, viral hooks, short-form patterns | TikTok search, trending page |
| **X (Twitter)** | Real-time trends, hot takes, thread structures | X search, lists, bookmarks |
| **Instagram** | Visual trends, carousel formats, Reels patterns | IG search, Reels tab |
| **YouTube** | Long-form depth, tutorial formats, retention patterns | YouTube search, trending |
| **LinkedIn** | B2B angles, professional pain points, case studies | LinkedIn search, hashtags |

**Format Migration Signals**:

Watch for content that performs well on one platform and hasn't migrated to others yet.

**Migration opportunities**:

```markdown
## Format Migration: [Topic]

**Origin Platform**: [Where it's working]
**Format**: [Carousel, thread, short video, etc.]
**Performance**: [Engagement metrics if available]
**Target Platform**: [Where to migrate it]
**Adaptation Required**: [What needs to change]

**Example**:
- Origin: X thread on "10 AI tools for marketers" (5K likes)
- Target: LinkedIn carousel (same content, professional design)
- Target: YouTube Short (video version with voiceover)
- Target: Blog post (expanded with screenshots, tutorials)
```

**Cross-platform content matrix**:

| Topic | Reddit | TikTok | X | IG | YouTube | LinkedIn | Blog |
|-------|--------|--------|---|----|---------|---------| ------|
| [topic 1] | [status] | [status] | [status] | [status] | [status] | [status] | [status] |

Status: `✓` (exists), `○` (opportunity), `✗` (poor fit)

**Why this works**: Content that works on one platform often works on others with format adaptation. You're finding proven ideas and multiplying them across channels.

**Related**: See `content/distribution/` for platform-specific adaptation guides.

**Audience profile template**:

```markdown
## Audience Profile: [Segment Name]

- **Who**: [Job title / role / demographic]
- **Pain points**: [Top 3 problems they need solved — use exact language from research]
- **Failed solutions**: [What they've tried that didn't work]
- **Goals**: [What success looks like for them]
- **Knowledge level**: [Beginner / Intermediate / Expert]
- **Where they hang out**: [Platforms, forums, communities — be specific]
- **Content preferences**: [Format: video, long-form, quick tips, tools]
- **Search behaviour**: [Question-style queries, comparison queries, how-to]
- **Buying triggers**: [What moves them from research to action — from pain point extraction]
- **Exact language**: [Key phrases they use repeatedly]
```

**Validation signals** (at least 2 required before proceeding):

| Signal | Source | Threshold |
|--------|--------|-----------|
| Search volume exists | DataForSEO / GSC | >100 monthly searches for primary keyword |
| Forum activity | Reddit, Quora, niche forums | Active threads in last 90 days |
| Competitor content exists | SERP analysis | 3+ competitors publishing on topic |
| Social engagement | LinkedIn, X | Posts on topic get meaningful engagement |
| Reddit discussion depth | 11-Dimension analysis | At least 5 dimensions show active discussion |

### 2. Niche Validation

Before investing in a content cluster, validate the niche is worth pursuing.

#### Niche Viability Formula

**Formula**: `Viability Score = (Demand × Buying Intent × (1 / Competition)) × Business Fit`

A niche is viable when:
- **Demand exists** (people are searching/talking about it)
- **Buying intent is present** (they're willing to pay for solutions)
- **Competition is manageable** (you can rank/get noticed)
- **Business fit is strong** (aligns with your monetization model)

**Validation workflow**:

1. **Demand Validation** (Google Trends + Reddit + Whop)

   **Google Trends**:
   - Search your primary keyword
   - Check trend direction: ↗ (growing), → (stable), ↘ (declining)
   - Minimum threshold: Stable or growing over 12 months
   - Regional interest: Where is demand strongest?

   **Reddit Activity**:
   - Search subreddits for your niche
   - Active = new posts in last 7 days, 10+ comments per post
   - Minimum threshold: 3+ active subreddits OR 1 large subreddit (50K+ members)

   **Whop Marketplace** (for digital products):
   - Search for products in your niche: https://whop.com/discover/
   - Check: How many sellers? What price points? Reviews/sales indicators?
   - Minimum threshold: 3+ active sellers = proven demand

   **Demand Score** (1-5):
   - 5: Growing trend + very active Reddit + 10+ Whop sellers
   - 4: Stable trend + active Reddit + 5+ Whop sellers
   - 3: Stable trend + moderate Reddit + 2-4 Whop sellers
   - 2: Declining trend OR low Reddit activity OR 0-1 Whop sellers
   - 1: No signals on any platform

2. **Buying Intent Validation**

   Look for commercial signals (people spending money, not just talking):

   **High buying intent signals**:
   - Reddit threads: "best [product] to buy", "worth paying for?", "which [service] should I get?"
   - Google Trends: "buy", "price", "cost", "vs" (comparison) in related queries
   - Whop: Active sales (reviews, seller count, price points $5-$500+)
   - Affiliate programs exist for products in this niche
   - Ads running (if people are paying for ads, there's money to be made)

   **Low buying intent signals**:
   - Only informational queries ("what is", "how does")
   - No paid products/services in the space
   - Reddit discussions are theoretical, not purchase-focused
   - No ads running (no one monetizing = hard to monetize)

   **Buying Intent Score** (1-5):
   - 5: Multiple commercial signals, high price points ($100+), active marketplace
   - 4: Clear commercial intent, mid price points ($20-$100), some marketplace activity
   - 3: Mixed signals, low price points ($5-$20), limited marketplace
   - 2: Mostly informational, few commercial signals
   - 1: No commercial signals, free-only mindset

3. **Competition Assessment**

   **SERP Analysis** (for SEO/content):
   - Search primary keyword in Google
   - Check Domain Authority of top 10 (use Moz, Ahrefs, or similar)
   - High competition: DA 70+ sites dominate top 10
   - Medium competition: Mix of DA 40-70
   - Low competition: DA <40 sites in top 10, or thin content

   **Social/Platform Competition**:
   - YouTube: How many channels cover this? Subscriber counts?
   - TikTok: How saturated is the hashtag? Can you differentiate?
   - Whop: How many sellers? Are they all established or is there room?

   **Competition Score** (1-5, inverted — lower competition = higher score):
   - 5: Low competition (DA <40, few creators, unsaturated)
   - 4: Medium-low (DA 40-60, some creators, room to differentiate)
   - 3: Medium (DA 60-70, established creators, need unique angle)
   - 2: High (DA 70-85, many established creators, hard to break in)
   - 1: Very high (DA 85+, dominated by major brands, nearly impossible)

4. **Business Fit Assessment**

   How well does this niche align with your monetization model?

   **Monetization models** (in order of cold traffic viability):
   - **Affiliates** (easiest): Recommend existing products, earn commission
   - **Info products** ($5-$27): Guides, templates, mini-courses (cold traffic works)
   - **Courses/coaching** ($100-$5K): Requires trust, warm traffic
   - **SaaS/tools** ($10-$100/mo): High LTV, longer sales cycle
   - **Services** ($500+): Highest friction, needs warm leads

   **Business Fit Score** (1-5):
   - 5: Perfect alignment (affiliate products exist + you can create info products)
   - 4: Strong alignment (can monetize with existing model)
   - 3: Moderate alignment (requires new monetization path)
   - 2: Weak alignment (hard to monetize with your model)
   - 1: No alignment (can't monetize this niche)

**Niche Viability Scorecard**:

| Factor | Weight | Score (1-5) | Weighted | Notes |
|--------|--------|-------------|----------|-------|
| Demand | 30% | | | Google Trends + Reddit + Whop |
| Buying Intent | 30% | | | Commercial signals, price points |
| Competition (inverted) | 25% | | | Lower competition = higher score |
| Business Fit | 15% | | | Monetization alignment |
| **TOTAL** | **100%** | | | **Weighted average** |

**Scoring**:

- **4.0+**: Strong niche -- proceed with pillar + cluster strategy, allocate budget
- **3.5-3.9**: Viable -- start with 2-3 test pieces, measure performance before scaling
- **3.0-3.4**: Marginal -- only pursue if Business Fit is 5 (strategic importance)
- **2.5-2.9**: Weak -- deprioritise, redirect effort to higher-scoring niches
- **<2.5**: Skip -- not worth the investment

**Q4 Seasonality Bonus**: If researching in Q4 (Oct-Dec), add +0.5 to Buying Intent score. Q4 has highest buying intent across most niches (holiday shopping, end-of-year budgets, New Year's resolutions).

**Validation steps**:

1. **Keyword landscape**: Pull primary keyword + 10-20 related terms with volume and difficulty

   ```bash
   # Use DataForSEO or keyword research tools
   # See seo/keyword-research.md for detailed workflow
   ```

2. **SERP analysis**: For the primary keyword, assess top 10 results

   ```markdown
   | Position | Domain | DA | Word Count | Content Type | Freshness | Gaps |
   |----------|--------|----|------------|--------------|-----------|------|
   | 1 | example.com | 85 | 3200 | Guide | 2025-06 | No video |
   | 2 | ... | ... | ... | ... | ... | ... |
   ```

3. **Content quality audit**: Read top 3 results and note:
   - What they cover well
   - What they miss (your opportunity)
   - Depth and specificity (vague = opportunity)
   - Freshness (outdated = opportunity)
   - Format gaps (no templates, no tools, no video)

4. **Business alignment check**: Can this topic lead to a conversion? Map the funnel:

   ```text
   Awareness: "what is [topic]" -> Informational article
   Consideration: "best [topic] tools" -> Comparison article
   Decision: "[your product] for [topic]" -> Landing page / case study
   ```

### 3. Competitor Content Analysis

Systematic analysis of what competitors publish, how it performs, and where the gaps are.

**Competitor identification**:

1. Search primary keyword -- note domains in positions 1-10
2. Check `context/competitor-analysis.md` if it exists (from `context-templates.md`)
3. Identify 3-5 direct competitors (same audience, similar products/services)

**Per-competitor analysis**:

```markdown
## Competitor: [Name] ([domain.com])

### Content Overview
- **Publishing frequency**: [X posts/month]
- **Primary topics**: [list top 3-5 topic clusters]
- **Content types**: [blog, video, podcast, tools, templates]
- **Average word count**: [X words]
- **Estimated organic traffic**: [if available from DataForSEO]

### Strengths
- [What they do well -- specific examples]

### Weaknesses
- [What they miss or do poorly -- specific examples]

### Content Gaps We Can Exploit
- [Topic they don't cover]
- [Angle they miss]
- [Format they don't use]
- [Audience segment they ignore]
```

**Competitor content matrix**:

| Topic | Us | Competitor A | Competitor B | Competitor C | Gap? |
|-------|-----|-------------|-------------|-------------|------|
| [topic 1] | [status] | [status] | [status] | [status] | [Y/N] |
| [topic 2] | [status] | [status] | [status] | [status] | [Y/N] |

Status values: `none`, `thin` (<500 words), `basic` (500-1500), `comprehensive` (1500+), `pillar` (3000+)

### 4. Research Brief Output

Compile findings into a structured brief that feeds into content planning and writing.

**Research brief template**:

```markdown
# Content Research Brief: [Topic/Niche]

**Date**: [YYYY-MM-DD]
**Researcher**: [agent/human]
**Niche score**: [X.X/5.0]

## Audience
[Audience profile from step 1]

## Niche Viability
[Scorecard from step 2]

## Keyword Targets
| Keyword | Volume | Difficulty | Intent | Priority |
|---------|--------|------------|--------|----------|
| [primary] | [vol] | [diff] | [intent] | P0 |
| [secondary 1] | [vol] | [diff] | [intent] | P1 |
| [secondary 2] | [vol] | [diff] | [intent] | P1 |
| [long-tail 1] | [vol] | [diff] | [intent] | P2 |

## Competitor Landscape
[Summary from step 3]

## Content Opportunities
1. [Highest-priority gap with rationale]
2. [Second gap]
3. [Third gap]

## Recommended Content Plan
| Priority | Title | Type | Target Keyword | Word Count | Funnel Stage |
|----------|-------|------|----------------|------------|--------------|
| P0 | [title] | [pillar/cluster/satellite] | [keyword] | [count] | [stage] |
| P1 | [title] | [type] | [keyword] | [count] | [stage] |

## Next Steps
- [ ] Populate `context/target-keywords.md` with keyword targets
- [ ] Update `context/competitor-analysis.md` with findings
- [ ] Add topics to content calendar
- [ ] Brief writer with this research for first article
```

## Storing Research

Save research outputs to the project's `context/` directory (see `content/context-templates.md`):

- `context/audience-profiles.md` -- audience segments and personas
- `context/competitor-analysis.md` -- competitor content matrix
- `context/target-keywords.md` -- validated keyword targets
- `context/niche-scorecards.md` -- niche validation results

These files are read automatically by `content/seo-writer.md` and `content/editor.md` during content creation.

## Integration

- **Feeds into**: `content/seo-writer.md` (writing brief), `tools/content/content-calendar.md` (topic prioritisation), `content/context-templates.md` (stores findings)
- **Uses data from**: `seo/dataforseo.md` (keyword data), `seo/google-search-console.md` (existing performance), `seo/keyword-research.md` (keyword discovery)
- **Related**: `research.md` (general research agent), `seo/content-analyzer.md` (post-writing analysis)
