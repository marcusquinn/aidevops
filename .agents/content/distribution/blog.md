---
name: blog
description: Blog distribution - SEO-optimized articles from content pipeline assets
mode: subagent
model: sonnet
---

# Blog - SEO-Optimized Article Distribution

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Transform content pipeline assets into SEO-optimized blog articles
- **Format**: Long-form articles (1,500-3,000 words), pillar content, supporting posts
- **Key Principle**: Research-backed, keyword-targeted, human-readable content
- **Success Metrics**: Organic traffic, time on page, scroll depth, conversions

**Critical Rules**:

- **Keyword-first** - Every article targets a primary keyword with validated search volume
- **Human voice** - AI-generated content must pass through `content/humanise.md` and `content/editor.md`
- **Internal linking** - 3-5 internal links per article using `content/internal-linker.md`
- **Meta optimization** - Title tag, meta description, and OG tags via `content/meta-creator.md`
- **One sentence per paragraph** - Per `content/guidelines.md` standards

**Legacy Content Tools** (integrated into this workflow):

- `content/seo-writer.md` - SEO-optimized writing
- `content/editor.md` - Human voice transformation
- `content/humanise.md` - Remove AI writing patterns
- `content/meta-creator.md` - Meta titles and descriptions
- `content/internal-linker.md` - Strategic internal linking
- `content/context-templates.md` - Per-project SEO context

<!-- AI-CONTEXT-END -->

## Article Types

### Pillar Content (2,000-3,000 words)

Comprehensive guides that target high-volume keywords and serve as link hubs.

**Structure**:

1. **Title** - Keyword-front, under 60 characters, value hook
2. **Meta description** - 150-160 characters, includes keyword, compelling CTA
3. **Introduction** (100-150 words) - Hook, problem statement, what the reader will learn
4. **Table of contents** - Jump links for articles over 1,500 words
5. **Body sections** (H2/H3 hierarchy) - One topic per section, scannable
6. **Key takeaways** - Bulleted summary of main points
7. **CTA** - Newsletter signup, related content, or product link
8. **FAQ section** - Target featured snippet opportunities

**Example**:

```text
Story: "Why 95% of AI influencers fail"

Pillar Article:
Title: Why 95% of AI Influencers Fail (And How to Be in the 5%)
H2: The AI Content Gold Rush
H2: 5 Mistakes That Kill AI Influencer Careers
  H3: Mistake 1 - Chasing Tools Instead of Problems
  H3: Mistake 2 - Publishing Unedited AI Content
  H3: Mistake 3 - Ignoring Audience Research
  H3: Mistake 4 - No Testing or Optimization
  H3: Mistake 5 - One-Off Posts Instead of Systems
H2: What the Top 5% Do Differently
H2: Building Your AI Content System
H2: Key Takeaways
H2: FAQ
```

### Supporting Posts (800-1,500 words)

Focused articles that target long-tail keywords and link back to pillar content.

**Structure**:

1. **Title** - Long-tail keyword, specific angle
2. **Introduction** (50-100 words) - Quick hook, what the reader will learn
3. **Body** (3-5 H2 sections) - Focused, actionable content
4. **Internal link** to pillar content
5. **CTA** - Related content or conversion action

### Listicles (1,000-2,000 words)

Numbered lists that target "best", "top", and "how to" keywords.

**Structure**:

1. **Title** - Number + keyword + year (e.g., "7 Best AI Video Tools in 2026")
2. **Introduction** - Selection criteria, what makes the list
3. **Numbered items** - Each with H2, description, pros/cons, use case
4. **Comparison table** - Quick-reference summary
5. **Verdict** - Recommendation based on use case

## SEO Workflow

### 1. Keyword Research

**From `seo/keyword-research.md` and `seo/dataforseo.md`**:

```bash
# Research keywords for a topic
keyword-research-helper.sh volume "AI video generation tools"
keyword-research-helper.sh related "AI video generation"
keyword-research-helper.sh difficulty "AI video generation tools"
```

**Keyword Selection Criteria**:

| Factor | Target |
|--------|--------|
| **Monthly volume** | 500+ for pillar, 100+ for supporting |
| **Keyword difficulty** | Under 40 for new sites, under 60 for established |
| **Search intent** | Informational or commercial investigation |
| **SERP features** | Featured snippet opportunity = priority |

### 2. Content Brief

Before writing, create a brief:

- **Primary keyword** and 3-5 secondary keywords
- **Search intent** (informational, commercial, transactional)
- **Target word count** based on SERP analysis
- **Competitor analysis** - Top 5 ranking articles, their structure and gaps
- **Unique angle** - What will this article offer that competitors don't?
- **Internal links** - Which existing articles to link to/from

### 3. Writing

**Pipeline integration**:

1. **Story** from `content/story.md` provides narrative framework
2. **Research** from `content/research.md` provides data and insights
3. **SEO writer** (`content/seo-writer.md`) drafts keyword-optimized content
4. **Editor** (`content/editor.md`) transforms to human voice
5. **Humanise** (`content/humanise.md`) removes AI patterns
6. **Meta creator** (`content/meta-creator.md`) generates title tag and meta description
7. **Internal linker** (`content/internal-linker.md`) adds strategic internal links

### 4. On-Page Optimization

**Checklist**:

- [ ] Primary keyword in title tag (first 60 chars)
- [ ] Primary keyword in H1
- [ ] Primary keyword in first 100 words
- [ ] Primary keyword in meta description
- [ ] Secondary keywords in H2 headings
- [ ] Alt text on all images (include keyword where natural)
- [ ] Internal links (3-5 per article)
- [ ] External links to authoritative sources (2-3 per article)
- [ ] URL slug contains primary keyword
- [ ] Schema markup (Article, FAQ, HowTo as applicable)

### 5. Content Analysis

```bash
# Full content analysis
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze article.md --keyword "target keyword"

# Individual checks
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md --keyword "keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md
```

## Content from Pipeline Assets

### From YouTube Video

1. **Extract transcript** using `youtube-helper.sh transcript VIDEO_ID`
2. **Restructure** for reading (video scripts are conversational, articles are structured)
3. **Add SEO elements** - keyword optimization, meta tags, internal links
4. **Expand** with additional research, examples, and data
5. **Add visuals** - Screenshots, diagrams, embedded video

### From Research Phase

1. **Use research brief** as article foundation
2. **Structure** around key findings
3. **Add original analysis** and expert perspective
4. **Include data** - Stats, charts, comparisons
5. **Link to sources** for credibility

### From Short-Form Content

1. **Expand** a high-performing short into a full article
2. **Add depth** - Context, examples, methodology
3. **Target related long-tail keywords**
4. **Embed** the original short-form video

## Publishing Workflow

### WordPress Integration

**From `tools/wordpress/wp-dev.md`**:

- Draft creation via WP REST API or WP-CLI
- Category and tag assignment
- Featured image upload
- Yoast/RankMath SEO fields
- Scheduled publishing

### Content Calendar

**From `content/optimization.md`**:

- **Pillar content**: 1-2 per month
- **Supporting posts**: 2-4 per week
- **Listicles**: 1-2 per month
- **Updates**: Refresh top-performing articles quarterly

### Post-Publish Checklist

- [ ] Verify indexing (Google Search Console)
- [ ] Share on social channels (`content/distribution/social.md`)
- [ ] Include in next newsletter (`content/distribution/email.md`)
- [ ] Internal link from 2-3 existing articles
- [ ] Monitor rankings for target keyword (weekly for first month)

## Related Agents and Tools

**Content Pipeline**:

- `content/research.md` - Audience research and niche validation
- `content/story.md` - Hook formulas and narrative design
- `content/guidelines.md` - Content standards and style guide
- `content/optimization.md` - A/B testing and analytics loops

**SEO**:

- `seo.md` - SEO orchestrator
- `seo/keyword-research.md` - Keyword volume and difficulty
- `seo/dataforseo.md` - SERP data and competitor analysis
- `seo/google-search-console.md` - Performance monitoring
- `seo/content-analyzer.md` - Content quality scoring

**Distribution Channels**:

- `content/distribution/youtube/` - Long-form YouTube content
- `content/distribution/short-form.md` - TikTok, Reels, Shorts
- `content/distribution/social.md` - X, LinkedIn, Reddit
- `content/distribution/email.md` - Newsletters and sequences
- `content/distribution/podcast.md` - Audio-first distribution

**WordPress**:

- `tools/wordpress/wp-dev.md` - WordPress development and API
- `tools/wordpress/mainwp.md` - Multi-site management
