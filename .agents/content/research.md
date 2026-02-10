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

Pre-production research to validate niches, understand audiences, and analyze competitors before committing to content creation. Research is the highest-leverage phase — 1 hour of research prevents 10 hours of producing content nobody wants.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Audience research, niche validation, competitor content analysis
- **Input**: Topic, niche, competitor URLs, or market to analyze
- **Output**: Research brief with audience profile, niche viability score, competitor gaps, pain points
- **Related**: `content/story.md` (uses research output), `youtube/channel-intel.md` (channel-specific research), `youtube/topic-research.md` (YouTube topic validation)

**Key Methods**:
- **11-Dimension Reddit Research** — comprehensive market intelligence via Perplexity
- **30-Minute Expert Method** — Reddit scraping → NotebookLM → instant expertise
- **Niche Viability Formula** — Demand + Buying Intent + Low Competition
- **Creator Brain Clone** — bulk transcript ingestion for competitive intel
- **Gemini Video Reverse-Engineering** — extract prompts from competitor videos
- **Pain Point Extraction** — exact audience language from forums/Reddit

<!-- AI-CONTEXT-END -->

## Research Frameworks

### 1. 11-Dimension Reddit Research Framework

The most comprehensive pre-production research method. Use Perplexity (or similar AI search) to systematically analyze a niche across 11 dimensions using Reddit as the primary signal source.

**Why Reddit**: Unfiltered audience voice. People share real problems, failed solutions, buying decisions, and frustrations. Reddit threads reveal what marketing copy hides.

**Perplexity Mega-Prompt Template**:

```text
I'm researching [NICHE/PRODUCT/TOPIC] for content creation. Please analyze Reddit discussions across these 11 dimensions and provide specific examples with thread links:

1. SENTIMENT: What is the overall sentiment toward [TOPIC]? (Positive, negative, mixed, evolving)
   - Find threads showing strong opinions (love it, hate it, disappointed, excited)
   - Note sentiment shifts over time (e.g., initial hype → disillusionment)

2. USER EXPERIENCE: What do users say about actually using [PRODUCT/SERVICE/APPROACH]?
   - Onboarding experience (easy, confusing, overwhelming)
   - Day-to-day usage (smooth, buggy, frustrating)
   - Learning curve (intuitive, steep, requires training)
   - Real-world results vs expectations

3. COMPETITORS: What alternatives do users compare [TOPIC] to?
   - Direct competitors mentioned in "X vs Y" threads
   - Migration stories ("I switched from X to Y because...")
   - Feature comparisons users care about
   - Why users chose one over another

4. PRICING: What do users say about cost and value?
   - "Too expensive" complaints with context
   - "Worth it" endorsements with reasoning
   - Pricing tier discussions (which plan to choose)
   - Cost-benefit analysis from real users
   - Budget constraints and workarounds

5. USE CASES: What are people actually using [TOPIC] for?
   - Intended use cases vs actual use cases
   - Creative/unexpected applications
   - Use cases by user segment (beginners, pros, enterprises)
   - "I use it for..." statements

6. SUPPORT & COMMUNITY: What do users say about getting help?
   - Support responsiveness and quality
   - Community helpfulness (forums, Discord, subreddit)
   - Documentation quality (clear, outdated, missing)
   - Self-service vs needing hand-holding

7. PERFORMANCE & RELIABILITY: Technical experience reports
   - Speed, uptime, stability mentions
   - Bugs and issues (recurring themes)
   - Scalability experiences
   - Platform/device-specific problems

8. UPDATES & ROADMAP: User reactions to changes
   - Feature requests (most upvoted, most discussed)
   - Update announcements (excitement, disappointment)
   - Abandoned features users miss
   - "They finally added..." celebrations

9. POWER USER TIPS: Advanced insights from experienced users
   - "Pro tips" and "hidden features" threads
   - Workflow optimizations
   - Integration and automation setups
   - "I wish I knew this earlier" advice

10. RED FLAGS: Warnings, complaints, deal-breakers
    - "Avoid if..." warnings
    - Migration-away stories ("Why I left...")
    - Unresolved pain points
    - Trust issues (privacy, security, vendor lock-in)

11. DECISION SUMMARY: Synthesize buying decision patterns
    - What pushes users from research to purchase?
    - What makes users choose [TOPIC] over alternatives?
    - What makes users reject [TOPIC]?
    - Common decision criteria (must-haves, nice-to-haves, deal-breakers)

For each dimension, provide:
- 2-3 direct quotes from Reddit threads (with context)
- Thread links for verification
- Patterns across multiple threads (not just one-off opinions)
- Recency (prioritize threads from last 12 months)

Focus on subreddits: [LIST RELEVANT SUBREDDITS, e.g., r/SaaS, r/Entrepreneur, r/ProductManagement, niche-specific subs]
```

**How to use the output**:

1. **Sentiment** → Informs your angle (contrarian if sentiment is negative, validation if positive, "here's the truth" if mixed)
2. **User Experience** → Pain points for hooks, transformation stories for case studies
3. **Competitors** → Comparison content opportunities, differentiation angles
4. **Pricing** → Objection handling, value demonstration, pricing tier content
5. **Use Cases** → Content ideas (one piece per use case), audience segmentation
6. **Support** → Trust-building content, community-building strategy
7. **Performance** → Technical credibility signals, what to emphasize/de-emphasize
8. **Updates** → Feature announcement content, roadmap-based content calendar
9. **Power User Tips** → Advanced content for retention, community engagement hooks
10. **Red Flags** → Objections to address, competitive advantages to highlight
11. **Decision Summary** → Sales page copy, landing page structure, CTA strategy

**Storage**: Save the full Perplexity output to `context/reddit-research-[NICHE].md` for reference during content creation.

### 2. 30-Minute Expert Method

Become a credible expert in any niche in 30 minutes by ingesting Reddit discussions through NotebookLM.

**Workflow**:

1. **Scrape Reddit** (5 minutes)
   - Use Perplexity or manual search: `site:reddit.com [NICHE] [KEYWORD]`
   - Collect 10-20 high-quality threads (100+ comments each)
   - Focus on: "What's your experience with...", "X vs Y", "Why I switched to...", "Avoid these mistakes"
   - Copy full thread text (including comments) into a text file

2. **Ingest into NotebookLM** (2 minutes)
   - Upload the Reddit thread compilation as a source
   - Add any competitor blog posts, YouTube transcripts, or documentation
   - Let NotebookLM index the content

3. **Extract Insights** (23 minutes)
   - Ask NotebookLM: "What are the top 10 pain points mentioned?"
   - Ask: "What solutions have people tried and failed with?"
   - Ask: "What language and phrases do people use to describe their problems?"
   - Ask: "What are the most common objections to [PRODUCT/APPROACH]?"
   - Ask: "What results do people want but aren't getting?"
   - Ask: "Summarize the decision criteria for choosing between [X] and [Y]"

**Output**: You now have:
- Exact audience language (for hooks and copy)
- Pain points ranked by frequency
- Failed solutions (your opportunity)
- Objections to address
- Desired outcomes (your promise)

**Why this works**: You're not guessing what the audience wants — you're reading their unfiltered conversations. NotebookLM synthesizes patterns across hundreds of comments faster than manual reading.

**Storage**: Save NotebookLM chat export to `context/notebooklm-[NICHE]-insights.md`

### 3. Niche Viability Formula

**Formula**: `Viability = Demand × Buying Intent × (1 / Competition)`

A niche is viable when:
1. **Demand exists** (people are searching/talking about it)
2. **Buying intent exists** (people are willing to pay for solutions)
3. **Competition is low** (you can rank/get noticed)

**Step-by-step validation**:

#### 3.1 Demand Validation

**Google Trends** (free):
- Search your primary keyword
- Check: Is the trend flat, growing, or declining?
- **Pass threshold**: Steady or growing over 12 months
- **Fail signal**: Declining trend or no data

**Whop Marketplace** (buying intent proxy):
- Search: `site:whop.com [NICHE]`
- Check: Are people selling info products in this niche?
- **Pass threshold**: 3+ active products with reviews
- **Fail signal**: No products or abandoned products

**Reddit Activity** (conversation volume):
- Search: `site:reddit.com [NICHE] [KEYWORD]`
- Check: Active threads in last 90 days?
- **Pass threshold**: 10+ threads with 20+ comments each
- **Fail signal**: No recent activity or one-off questions

**YouTube Search Volume** (content demand):
- Search your keyword on YouTube
- Check: Are there videos with 10K+ views?
- **Pass threshold**: Multiple creators covering the topic
- **Fail signal**: Only 1-2 creators or low view counts

#### 3.2 Buying Intent Validation

**Whop Product Pricing** (willingness to pay):
- Find products in your niche on Whop
- Check: What are people charging? $5-27 for cold traffic, $50-200 for warm
- **Pass threshold**: Products priced $20+ with sales
- **Fail signal**: Only free or <$5 products

**Affiliate Programs** (commercial ecosystem):
- Search: "[NICHE] affiliate program"
- Check: Do affiliate programs exist?
- **Pass threshold**: 3+ affiliate programs with >10% commission
- **Fail signal**: No affiliate programs (no one monetizing)

**Google Ads Competition** (advertiser demand):
- Use Google Keyword Planner (free with Google Ads account)
- Check: "Competition" column for your keywords
- **Pass threshold**: Medium or High competition (advertisers are bidding)
- **Fail signal**: Low competition (no one willing to pay for traffic)

**Reddit Purchase Discussions**:
- Search: `site:reddit.com [NICHE] "worth it" OR "should I buy" OR "is it worth"`
- Check: Are people asking buying advice?
- **Pass threshold**: Active purchase decision threads
- **Fail signal**: No buying discussions

#### 3.3 Competition Assessment

**SERP Analysis** (organic competition):
- Google your primary keyword
- Check top 10 results:
  - Domain Authority (use Moz, Ahrefs, or SEMrush free tools)
  - Content quality (comprehensive vs thin)
  - Freshness (recent vs outdated)
- **Pass threshold**: 3+ results with DA <40 OR outdated content (>2 years old)
- **Fail signal**: All results are DA 70+ with fresh, comprehensive content

**YouTube Competition** (video competition):
- Search your keyword on YouTube
- Check top 10 videos:
  - Subscriber count of creators
  - Video quality (production value)
  - View count relative to subscriber count
- **Pass threshold**: Top videos from creators with <50K subs OR low production value
- **Fail signal**: All top videos from 500K+ sub channels with high production

**Social Media Saturation**:
- Search hashtag on TikTok, Instagram, X
- Check: How many posts? How recent?
- **Pass threshold**: <10K posts OR mostly low-engagement posts
- **Fail signal**: 100K+ posts with high engagement (saturated)

#### 3.4 Viability Scorecard

| Factor | Weight | Score (1-5) | Evidence |
|--------|--------|-------------|----------|
| **Demand** | | | |
| Google Trends | 15% | | Growing/Flat/Declining |
| Whop Products | 10% | | # of active products |
| Reddit Activity | 10% | | # of recent threads |
| YouTube Views | 10% | | View counts on topic |
| **Buying Intent** | | | |
| Whop Pricing | 15% | | Price points with sales |
| Affiliate Programs | 10% | | # of programs, commission % |
| Google Ads Competition | 10% | | Low/Medium/High |
| Reddit Purchase Discussions | 5% | | # of buying threads |
| **Competition** | | | |
| SERP Difficulty | 10% | | DA of top 10, content gaps |
| YouTube Competition | 5% | | Sub counts, production quality |
| Social Saturation | 0% | | (informational only) |

**Scoring guide**:
- 5 = Excellent (strong signal, clear opportunity)
- 4 = Good (positive signal, viable)
- 3 = Moderate (mixed signal, proceed with caution)
- 2 = Weak (negative signal, high risk)
- 1 = Poor (no signal, avoid)

**Weighted Score Calculation**:
```
Total Score = Σ(Factor Score × Weight)
```

**Decision thresholds**:
- **4.0+**: Strong niche — invest in pillar content + multi-channel strategy
- **3.5-3.9**: Viable niche — start with 3-5 test pieces, measure performance
- **3.0-3.4**: Risky niche — only pursue if you have unique expertise or distribution
- **<3.0**: Avoid — redirect effort to better opportunities

**Q4 Seasonality Bonus**: If researching in Q4 (Oct-Dec), add +0.5 to buying intent factors. Q4 has highest buying intent across most niches.

### 4. Creator Brain Clone (Competitive Intelligence via Transcripts)

Bulk ingest competitor channel transcripts to understand their content strategy, audience, and gaps.

**Why transcripts > metadata**: Transcripts reveal:
- Exact language and phrases that resonate
- Story structures and hooks
- Pain points they address
- Objections they handle
- Calls to action
- Content gaps (what they don't cover)

**Workflow**:

1. **Identify Competitor Channels** (5 minutes)
   - Find 3-5 channels in your niche with 10K-500K subscribers
   - Avoid mega-channels (1M+) — their strategies don't translate to smaller channels
   - Prioritize channels with high engagement (views per subscriber >10%)

2. **Bulk Download Transcripts** (10 minutes)
   ```bash
   # Use yt-dlp-helper.sh (references youtube/channel-intel.md)
   yt-dlp-helper.sh transcripts @channelhandle --limit 50
   
   # Or manual yt-dlp:
   yt-dlp --write-auto-sub --skip-download \
     --output "transcripts/%(channel)s/%(title)s.%(ext)s" \
     "https://youtube.com/@channelhandle/videos"
   ```

3. **Ingest into Memory** (5 minutes)
   ```bash
   # Store in memory with youtube namespace for queryable intel
   memory-helper.sh store \
     --namespace youtube \
     --type COMPETITOR_INTEL \
     --content "$(cat transcripts/channelname/*.vtt)" \
     --tags "channel:@handle,niche:NICHE"
   ```

4. **Query for Insights** (ongoing)
   ```bash
   # What pain points do they address?
   memory-helper.sh recall --namespace youtube \
     "pain points mentioned by @channelhandle"
   
   # What hooks do they use?
   memory-helper.sh recall --namespace youtube \
     "video hooks used by @channelhandle"
   
   # What topics do they cover?
   memory-helper.sh recall --namespace youtube \
     "topics covered by @channelhandle"
   ```

5. **Alternative: NotebookLM Ingestion**
   - Concatenate all transcripts into one file
   - Upload to NotebookLM as a source
   - Ask: "What are the top 10 topics this channel covers?"
   - Ask: "What pain points does this channel address most often?"
   - Ask: "What hooks and angles does this channel use?"
   - Ask: "What topics are mentioned but not deeply covered?" (your gap)

**Output**: You now have a queryable "brain clone" of your competitor's content strategy.

**Use cases**:
- **Gap analysis**: What topics do they mention but not cover deeply?
- **Hook library**: What opening lines get the most engagement?
- **Audience intel**: What pain points do they address repeatedly?
- **Content calendar**: What topics can you cover better or differently?

**Storage**: Transcripts in `context/competitor-transcripts/[channel-name]/`, insights in `context/competitor-intel-[channel-name].md`

**Related**: See `youtube/channel-intel.md` for channel-specific research, `t201` for automation.

### 5. Gemini Video Reverse-Engineering

Extract reproducible prompts from competitor videos by feeding them to Gemini 3 (or similar vision model).

**Why this works**: AI video generation is prompt-driven. If you can reverse-engineer the prompt, you can reproduce (and improve) the style.

**Workflow**:

1. **Identify Target Videos** (5 minutes)
   - Find competitor videos with visual styles you want to replicate
   - Download video file or get shareable link
   - Focus on: AI-generated videos, motion graphics, specific visual aesthetics

2. **Feed to Gemini 3 Vision** (via Google AI Studio or API)
   ```text
   Prompt: "Analyze this video and extract a detailed prompt that could reproduce this visual style. Include:
   - Camera angles and movements
   - Lighting and color grading
   - Subject description (if applicable)
   - Scene composition
   - Motion and pacing
   - Any text overlays or graphics
   - Estimated AI tool used (Sora, Veo, Runway, etc.)
   
   Output the prompt in a format I can use with [TOOL]."
   ```

3. **Refine and Test**
   - Take Gemini's extracted prompt
   - Test with your AI video tool (Sora 2, Veo 3.1, etc.)
   - Iterate: adjust prompt based on output differences
   - Save working prompts to your style library

**Example Use Case**:
- Competitor has a viral video with a specific cinematic look
- Feed video to Gemini → get prompt
- Use prompt with Veo 3.1 → reproduce style
- Apply your own subject/message → differentiated content with proven visual style

**Storage**: Save extracted prompts to `context/video-prompts-library/[style-name].md`

**Related**: See `tools/video/video-prompt-design.md` for prompt engineering, `content/production/video.md` for video production workflows.

### 6. Pain Point Extraction Methodology

Extract exact audience language for hooks, copy, and content angles from Reddit and forums.

**Why exact language matters**: Your audience doesn't search for "optimize workflow efficiency" — they search for "why is this so slow" or "how do I stop wasting time on X". Use their words, not marketing jargon.

**Extraction Workflow**:

1. **Find Pain Point Threads** (10 minutes)
   - Reddit search: `site:reddit.com [NICHE] "frustrated" OR "annoying" OR "waste of time" OR "struggling with"`
   - Forum search: `site:forum.com [NICHE] "problem" OR "issue" OR "help"`
   - Look for threads with 20+ comments (validated pain, not one-off)

2. **Categorize Pain Points** (15 minutes)
   
   Create a pain point matrix:
   
   | Pain Point (exact quote) | Frequency | Failed Solutions | Purchase Trigger | Urgency |
   |--------------------------|-----------|------------------|------------------|---------|
   | "I waste 3 hours a day on..." | High (10+ mentions) | Tried X, Y, Z | "I can't keep doing this" | High |
   | "Why is [TASK] so complicated?" | Medium (5-9 mentions) | Tried X | "There has to be a better way" | Medium |
   | "I hate that [TOOL] doesn't..." | Low (2-4 mentions) | No attempts yet | "I wish..." | Low |

3. **Extract Failed Solutions** (10 minutes)
   - What have they already tried?
   - Why didn't it work? (too expensive, too complicated, didn't deliver results)
   - This is your differentiation angle: "Unlike X which [FAILURE], our approach [SOLUTION]"

4. **Identify Purchase Triggers** (10 minutes)
   - What language signals they're ready to buy?
   - "I can't keep doing this" = high urgency
   - "I need this done by [DATE]" = deadline urgency
   - "I'm willing to pay for..." = budget allocated
   - "What's the best [SOLUTION]?" = active research phase

5. **Map to Content Angles** (5 minutes)
   
   | Pain Point | Content Angle | Hook Example |
   |------------|---------------|--------------|
   | "I waste 3 hours a day on X" | Time-saving transformation | "I cut my [TASK] time from 3 hours to 15 minutes" |
   | "Why is X so complicated?" | Simplification | "The stupidly simple way to [TASK]" |
   | "I hate that X doesn't..." | Feature gap | "Finally, a [TOOL] that actually [FEATURE]" |

**Output**: A pain point library with exact audience language, failed solutions, and purchase triggers.

**Storage**: Save to `context/pain-points-[NICHE].md`

**Use in content**:
- **Hooks**: Use exact pain point language in first 3 seconds
- **Body**: Address failed solutions ("You've probably tried X, Y, Z — here's why they don't work")
- **CTA**: Trigger purchase language ("Stop wasting 3 hours a day — here's the solution")

### 7. Cross-Platform Research (Format Migration Signals)

Identify content that performs well on one platform and adapt it to others.

**Why cross-platform**: A viral TikTok can become a YouTube Short, a Twitter thread, a LinkedIn article, a blog post, and an email sequence. One research cycle → 10+ content pieces.

**Platform Research Workflow**:

#### 7.1 TikTok Research

**What to look for**:
- Trending sounds (can be repurposed with your niche angle)
- Viral formats (e.g., "POV:", "Storytime:", "Here's why...")
- High-engagement topics (>100K views in your niche)

**How to research**:
1. Search your niche keyword on TikTok
2. Filter by "Most Liked" (last 30 days)
3. Note: hook structure, visual style, pacing, sound choice
4. Extract: What made this go viral? (relatability, controversy, value, entertainment)

**Migration opportunity**: TikTok viral video → YouTube Short (same format) → YouTube long-form (expanded version) → blog post (text version)

#### 7.2 X (Twitter) Research

**What to look for**:
- High-engagement threads (1K+ likes)
- Contrarian takes (engagement bait)
- Data-driven posts (screenshots, charts)
- "How I..." success stories

**How to research**:
1. Search: `[NICHE] min_faves:1000` (advanced search)
2. Note: thread structure, hook, data points, CTA
3. Extract: What angle resonated? (contrarian, aspirational, educational)

**Migration opportunity**: Viral thread → LinkedIn article (professional tone) → blog post (SEO-optimized) → YouTube script (spoken version)

#### 7.3 Instagram Research

**What to look for**:
- Carousel posts (high engagement format)
- Reels with high saves (valuable content)
- Before/after transformations

**How to research**:
1. Search hashtag: #[NICHE]
2. Filter by "Top" posts
3. Note: visual style, caption structure, CTA

**Migration opportunity**: Carousel → blog post (one slide = one section) → YouTube video (one slide = one chapter)

#### 7.4 Reddit Research (Content Validation)

**What to look for**:
- High-upvote posts (500+ upvotes)
- Gilded posts (someone paid to highlight it)
- High-comment threads (100+ comments = engaged audience)

**How to research**:
1. Search: `site:reddit.com/r/[SUBREDDIT] top`
2. Filter by "Top" → "This Year"
3. Note: what questions get the most engagement? What advice gets the most upvotes?

**Migration opportunity**: Top Reddit post → YouTube video ("I answered Reddit's top question about X") → blog post (FAQ format)

#### 7.5 Cross-Platform Content Matrix

| Platform | Format | Engagement Signal | Migration Path |
|----------|--------|-------------------|----------------|
| TikTok | 15-60s video | >100K views, >10% engagement rate | → YouTube Short → YouTube long-form → blog |
| X (Twitter) | Thread (5-10 tweets) | >1K likes, >100 retweets | → LinkedIn article → blog post → email sequence |
| Instagram | Carousel (5-10 slides) | >1K saves, >5% engagement rate | → Blog post → YouTube chapters → PDF lead magnet |
| Reddit | Long-form post/comment | >500 upvotes, gilded | → YouTube video → blog post → newsletter |
| LinkedIn | Article (1000-2000 words) | >100 reactions, >20 comments | → Blog post → Twitter thread → YouTube script |

**Research Output**: A list of high-performing content pieces with migration paths.

**Storage**: Save to `context/cross-platform-opportunities.md`

**Workflow**:
1. Research across platforms (1 hour)
2. Identify top 10 pieces with migration potential
3. Prioritize by: engagement + relevance + ease of adaptation
4. Create adaptation briefs (one source → multiple outputs)
5. Dispatch to production (see `content/production/` and `content/distribution/`)

## Research Brief Template

After completing research, compile findings into a structured brief.

```markdown
# Content Research Brief: [NICHE/TOPIC]

**Date**: [YYYY-MM-DD]
**Researcher**: [agent/human]
**Niche Viability Score**: [X.X/5.0]

## Executive Summary

[2-3 sentences: Is this niche viable? What's the opportunity? What's the risk?]

## Audience Profile

**Primary Audience**: [Job title / role / demographic]

**Pain Points** (ranked by frequency):
1. [Pain point in exact audience language] — [Frequency: High/Medium/Low]
2. [Pain point 2]
3. [Pain point 3]

**Failed Solutions**:
- [What they've tried and why it didn't work]

**Purchase Triggers**:
- [Language that signals buying intent]

**Where They Hang Out**:
- [Platforms, subreddits, forums, communities]

**Content Preferences**:
- [Format: video, long-form, quick tips, tools]

## Niche Viability Analysis

### Demand Signals
- **Google Trends**: [Growing/Flat/Declining] — [Link to trends]
- **Whop Products**: [# of active products] — [Price range]
- **Reddit Activity**: [# of recent threads] — [Engagement level]
- **YouTube Search Volume**: [View counts on topic]

### Buying Intent Signals
- **Whop Pricing**: [Price points with sales]
- **Affiliate Programs**: [# of programs, commission %]
- **Google Ads Competition**: [Low/Medium/High]
- **Reddit Purchase Discussions**: [# of buying threads]

### Competition Assessment
- **SERP Difficulty**: [DA of top 10, content gaps]
- **YouTube Competition**: [Sub counts, production quality]
- **Social Saturation**: [Post counts, engagement levels]

**Viability Scorecard**: [Insert completed scorecard from Section 3.4]

**Recommendation**: [Strong/Viable/Risky/Avoid] — [Rationale]

## Competitor Intelligence

### Competitor 1: [Name] (@handle or domain)
- **Strengths**: [What they do well]
- **Weaknesses**: [What they miss or do poorly]
- **Content Gaps**: [Topics they don't cover or cover poorly]
- **Audience**: [Who engages with them]

### Competitor 2: [Name]
[Same structure]

### Competitor 3: [Name]
[Same structure]

**Competitive Advantage**: [How we can differentiate]

## Content Opportunities

### High-Priority Gaps (P0)
1. [Gap 1] — [Why this is an opportunity] — [Estimated demand]
2. [Gap 2]
3. [Gap 3]

### Medium-Priority Gaps (P1)
1. [Gap 4]
2. [Gap 5]

### Cross-Platform Migration Opportunities
| Source Platform | Content Piece | Engagement | Migration Path |
|-----------------|---------------|------------|----------------|
| [Platform] | [Title/Link] | [Metrics] | [Platforms to adapt to] |

## Pain Point Library

| Pain Point (exact quote) | Frequency | Failed Solutions | Purchase Trigger | Content Angle |
|--------------------------|-----------|------------------|------------------|---------------|
| [Quote] | [High/Med/Low] | [What they tried] | [Trigger language] | [Hook idea] |

## Keyword Targets

| Keyword | Volume | Difficulty | Intent | Priority |
|---------|--------|------------|--------|----------|
| [Primary keyword] | [vol] | [diff] | [Informational/Commercial/Transactional] | P0 |
| [Secondary 1] | [vol] | [diff] | [intent] | P1 |
| [Long-tail 1] | [vol] | [diff] | [intent] | P2 |

## Recommended Content Plan

| Priority | Title | Type | Target Keyword | Format | Funnel Stage | Est. Effort |
|----------|-------|------|----------------|--------|--------------|-------------|
| P0 | [Title] | [Pillar/Cluster] | [Keyword] | [Video/Blog/Both] | [Awareness/Consideration/Decision] | [Hours] |
| P1 | [Title] | [Type] | [Keyword] | [Format] | [Stage] | [Hours] |

## Next Steps

- [ ] Populate `context/target-keywords.md` with keyword targets
- [ ] Update `context/competitor-analysis.md` with competitor intel
- [ ] Save pain point library to `context/pain-points-[NICHE].md`
- [ ] Add top 3 content opportunities to content calendar
- [ ] Brief writer with this research for first piece (see `content/story.md`)

## Research Artifacts

- **11-Dimension Reddit Research**: `context/reddit-research-[NICHE].md`
- **NotebookLM Insights**: `context/notebooklm-[NICHE]-insights.md`
- **Competitor Transcripts**: `context/competitor-transcripts/[channel-name]/`
- **Competitor Intel**: `context/competitor-intel-[channel-name].md`
- **Video Prompt Library**: `context/video-prompts-library/[style-name].md`
- **Pain Points**: `context/pain-points-[NICHE].md`
- **Cross-Platform Opportunities**: `context/cross-platform-opportunities.md`
```

## Integration

- **Feeds into**: `content/story.md` (narrative design using research insights), `content/production/` (production briefs), `content/distribution/` (channel-specific adaptation)
- **Uses data from**: `seo/dataforseo.md` (keyword data), `seo/google-search-console.md` (existing performance), `youtube/channel-intel.md` (YouTube-specific research), `youtube/topic-research.md` (topic validation)
- **Related**: `tools/task-management/beads.md` (research task tracking), `memory/README.md` (storing research insights for cross-session recall)

## Storage Conventions

Save research outputs to the project's `context/` directory:

- `context/reddit-research-[NICHE].md` — 11-dimension Reddit research output
- `context/notebooklm-[NICHE]-insights.md` — NotebookLM chat export
- `context/competitor-transcripts/[channel-name]/` — Bulk transcripts
- `context/competitor-intel-[channel-name].md` — Competitor analysis
- `context/video-prompts-library/[style-name].md` — Extracted video prompts
- `context/pain-points-[NICHE].md` — Pain point library
- `context/cross-platform-opportunities.md` — Cross-platform content matrix
- `context/audience-profiles.md` — Audience segments and personas
- `context/target-keywords.md` — Validated keyword targets
- `context/niche-scorecards.md` — Niche viability scores

These files are read automatically by `content/story.md`, `content/seo-writer.md`, and `content/editor.md` during content creation.
