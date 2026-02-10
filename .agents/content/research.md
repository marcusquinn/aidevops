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

## Workflow

### 1. Audience Research

Identify who you are writing for before writing anything.

**Data sources** (in priority order):

1. **Google Search Console** (`seo/google-search-console.md`) -- existing query data reveals what your audience already searches for
2. **Competitor audiences** -- analyse who engages with competitor content (comments, shares, forums)
3. **Web search** -- use `websearch` or `webfetch` for industry reports, surveys, forum threads
4. **DataForSEO** (`seo/dataforseo.md`) -- keyword volume and demographics data

**Audience profile template**:

```markdown
## Audience Profile: [Segment Name]

- **Who**: [Job title / role / demographic]
- **Pain points**: [Top 3 problems they need solved]
- **Goals**: [What success looks like for them]
- **Knowledge level**: [Beginner / Intermediate / Expert]
- **Where they hang out**: [Platforms, forums, communities]
- **Content preferences**: [Format: video, long-form, quick tips, tools]
- **Search behaviour**: [Question-style queries, comparison queries, how-to]
- **Buying triggers**: [What moves them from research to action]
```

**Validation signals** (at least 2 required before proceeding):

| Signal | Source | Threshold |
|--------|--------|-----------|
| Search volume exists | DataForSEO / GSC | >100 monthly searches for primary keyword |
| Forum activity | Reddit, Quora, niche forums | Active threads in last 90 days |
| Competitor content exists | SERP analysis | 3+ competitors publishing on topic |
| Social engagement | LinkedIn, X | Posts on topic get meaningful engagement |

### 2. Niche Validation

Before investing in a content cluster, validate the niche is worth pursuing.

**Niche scorecard**:

| Factor | Weight | Score (1-5) | Notes |
|--------|--------|-------------|-------|
| Search demand | 30% | | Monthly volume for primary + long-tail keywords |
| Competition level | 25% | | Domain authority of top 10 results, content quality |
| Business relevance | 25% | | Alignment with products/services, conversion potential |
| Content gap | 10% | | Topics competitors miss or cover poorly |
| Expertise match | 10% | | Can we credibly cover this? (E-E-A-T) |

**Scoring**:

- **4.0+**: Strong niche -- proceed with pillar + cluster strategy
- **3.0-3.9**: Viable -- start with 2-3 test articles, measure performance
- **2.0-2.9**: Weak -- deprioritise unless business relevance is 5
- **<2.0**: Skip -- redirect effort elsewhere

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
