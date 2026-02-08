---
description: SEO content creation workflow inspired by SEO Machine
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
  task: true
---

# SEO Content Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: End-to-end SEO content creation, optimization, and analysis
- **Inspired by**: [TheCraigHewitt/seomachine](https://github.com/TheCraigHewitt/seomachine)
- **Commands**: `/research`, `/write`, `/optimize`, `/analyze`, `/rewrite`
- **Analysis**: Readability scoring, keyword density, search intent, SEO quality rating

**Workflow**: Research → Write → Optimize → Publish → Monitor

<!-- AI-CONTEXT-END -->

## Content Creation Pipeline

### 1. Research (`/research`)

Gather data before writing:

```text
/research "target keyword" --competitors 5 --intent informational
```

Steps:
1. **Keyword analysis** via DataForSEO or Serper (`seo/keyword-research.md`)
2. **SERP analysis** - Top 10 results: word count, headings, schema markup
3. **Search intent classification** - Informational, navigational, transactional, commercial
4. **Content gap analysis** - What competitors cover that you don't
5. **E-E-A-T assessment** via `seo/eeat-score.md`

Output: Research brief with target word count, required headings, keywords, and content gaps.

### 2. Write (`/write`)

Generate content from research brief:

```text
/write --brief research-brief.md --voice brand-voice.md --length 2000
```

Steps:
1. Load brand voice and style guide (from project context)
2. Generate outline from research brief
3. Write sections with keyword integration
4. Add internal links from site link map
5. Generate meta title and description

### 3. Optimize (`/optimize`)

Score and improve existing content:

```text
/optimize content.md --target-keyword "main keyword"
```

Analysis modules:
- **Readability** - Flesch-Kincaid, Gunning Fog, sentence length
- **Keyword density** - Primary/secondary keyword distribution
- **SEO quality** - 0-100 score based on title, headings, meta, links, schema
- **Content length** - Compare against SERP competitors
- **Internal linking** - Suggest links from site map

### 4. Analyze (`/analyze`)

Audit existing published content:

```text
/analyze https://example.com/blog/post --competitors
```

Steps:
1. Fetch and parse page content
2. Run all optimization checks
3. Compare against top SERP competitors
4. Generate improvement recommendations
5. Score against E-E-A-T criteria

### 5. Rewrite (`/rewrite`)

Humanize or improve AI-generated content:

```text
/rewrite content.md --voice natural --preserve-seo
```

Focus areas:
- Remove AI patterns (repetitive transitions, filler phrases)
- Add personal experience signals (E-E-A-T)
- Vary sentence structure and length
- Maintain keyword optimization

## Analysis Functions

### Readability Scoring

```python
# Flesch Reading Ease (target: 60-70 for general audience)
# Gunning Fog Index (target: 8-12)
# Average sentence length (target: 15-20 words)
# Paragraph length (target: 3-5 sentences)
```

### Keyword Density

```python
# Primary keyword: 1-2% density
# Secondary keywords: 0.5-1% each
# LSI/related terms: natural distribution
# Keyword in: title, H1, first 100 words, meta description
```

### SEO Quality Score (0-100)

| Factor | Weight | Check |
|--------|--------|-------|
| Title tag | 15 | Contains keyword, 50-60 chars |
| Meta description | 10 | Contains keyword, 150-160 chars |
| H1 tag | 10 | Contains keyword, unique |
| Heading structure | 10 | H2/H3 hierarchy, keywords in subheadings |
| Content length | 10 | Meets/exceeds SERP average |
| Keyword density | 10 | 1-2% primary, natural distribution |
| Internal links | 10 | 3+ relevant internal links |
| External links | 5 | 2+ authoritative sources |
| Image optimization | 5 | Alt text, descriptive filenames |
| Schema markup | 5 | Article/FAQ/HowTo as appropriate |
| Readability | 5 | Flesch 60+, short paragraphs |
| URL structure | 5 | Contains keyword, short, descriptive |

### Search Intent Classification

| Intent | Signals | Content Type |
|--------|---------|-------------|
| **Informational** | how, what, why, guide | Blog post, tutorial |
| **Navigational** | brand name, specific site | Landing page |
| **Transactional** | buy, price, discount | Product page |
| **Commercial** | best, review, comparison | Comparison article |

## Context System

Store project-specific context for consistent content:

```text
project/
├── .seo-context/
│   ├── brand-voice.md      # Tone, style, vocabulary
│   ├── style-guide.md      # Formatting rules
│   ├── internal-links.json # Site link map
│   ├── target-keywords.csv # Keyword tracking
│   └── examples/           # Reference content
```

## Integration with Existing Tools

| Task | Tool |
|------|------|
| Keyword research | `seo/keyword-research.md`, `seo/dataforseo.md` |
| SERP analysis | `seo/serper.md`, `seo/semrush.md` |
| Site crawling | `seo/site-crawler.md`, `seo/screaming-frog.md` |
| E-E-A-T scoring | `seo/eeat-score.md` |
| Schema markup | `seo/schema-markup.md` |
| Content calendar | `tools/content/content-calendar.md` |
| Platform publishing | `tools/content/guidelines.md` |
| Performance monitoring | `seo/google-search-console.md` |

## Related

- `seo/keyword-research.md` - Keyword research tools
- `seo/eeat-score.md` - E-E-A-T quality assessment
- `seo/programmatic-seo.md` - Programmatic page generation
- `tools/content/content-calendar.md` - Content scheduling
- `tools/content/guidelines.md` - Platform-specific adaptations
