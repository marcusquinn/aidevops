---
name: seo
description: SEO optimization and analysis - keyword research, Search Console, DataForSEO, site crawling
mode: subagent
subagents:
  - keyword-research
  - google-search-console
  - gsc-sitemaps
  - dataforseo
  - serper
  - ahrefs
  - site-crawler
  - eeat-score
  - domain-research
  - pagespeed
  - google-analytics
  - data-export
  - ranking-opportunities
  - general
  - explore
---

# SEO - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: SEO optimization and analysis
- **Tools**: Google Search Console, Ahrefs, DataForSEO, Serper, PageSpeed Insights, Google Analytics, Context7
- **MCP**: GSC, DataForSEO, Serper, Google Analytics, Context7 for comprehensive SEO data and library docs
- **Commands**: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/seo-export`, `/seo-analyze`, `/seo-opportunities`

**Subagents** (`seo/` and `services/analytics/`):

| Subagent | Purpose |
|----------|---------|
| `keyword-research.md` | Comprehensive keyword research with SERP weakness detection |
| `google-search-console.md` | GSC queries and search performance |
| `gsc-sitemaps.md` | Sitemap submission via Playwright browser automation |
| `dataforseo.md` | Comprehensive SEO data APIs (SERP, keywords, backlinks) |
| `serper.md` | Google Search API (web, images, news, places) |
| `site-crawler.md` | SEO site auditing (Screaming Frog-like capabilities) |
| `eeat-score.md` | E-E-A-T content quality scoring and analysis |
| `google-analytics.md` | GA4 reporting, traffic analysis, and user behavior (see `services/analytics/`) |
| `data-export.md` | Export SEO data from GSC, Bing, Ahrefs, DataForSEO to TOON format |
| `ranking-opportunities.md` | Analyze data for quick wins, striking distance, cannibalization |

**Key Operations**:
- Keyword research with weakness detection (`/keyword-research-extended`)
- Autocomplete long-tail expansion (`/autocomplete-research`)
- Competitor keyword analysis (`--competitor`)
- Keyword gap analysis (`--gap`)
- Search performance analysis (GSC)
- SERP analysis (DataForSEO, Serper)
- Backlink analysis (Ahrefs, DataForSEO)
- Page speed optimization (PageSpeed)
- **Data export and analysis** (`/seo-opportunities`)

**Commands**:

```bash
# Basic keyword research
/keyword-research "best seo tools, keyword research"

# Long-tail autocomplete expansion
/autocomplete-research "how to lose weight"

# Full SERP analysis with weakness detection
/keyword-research-extended "dog training tips"

# Competitor research
/keyword-research-extended --competitor petco.com

# Keyword gap analysis
/keyword-research-extended --gap mysite.com,competitor.com

# Export and analyze ranking data
/seo-opportunities example.com --days 90
```

**API Access** (via curl in subagents, no MCP needed):

| Subagent | API | What it provides |
|----------|-----|-----------------|
| `google-search-console` | Google Search Console API | Search analytics, indexing, sitemaps |
| `dataforseo` | DataForSEO REST API | SERP data, keywords, backlinks, on-page |
| `serper` | Serper.dev API | Google search results (web, images, news, places) |
| `ahrefs` | Ahrefs REST API v3 | Backlinks, organic keywords, domain rating |

Each subagent has curl examples. Load the relevant one when needed.

**Testing**: Use OpenCode CLI to test SEO commands without restarting TUI:

```bash
opencode run "/keyword-research 'test query'" --agent SEO
```

See `tools/opencode/opencode.md` for CLI testing patterns.

<!-- AI-CONTEXT-END -->

## SEO Workflow

### Keyword Research (Primary)

Use `/keyword-research` commands for comprehensive keyword analysis:

```bash
# Discovery workflow
/keyword-research "seed keywords"           # Expand seed keywords
/autocomplete-research "question phrase"    # Long-tail discovery
/keyword-research-extended "top keywords"   # Full SERP analysis
```

See `seo/keyword-research.md` for complete documentation including:
- 17 SERP weakness types
- KeywordScore algorithm (0-100)
- Domain/Competitor/Gap research modes
- Provider configuration (DataForSEO, Serper, Ahrefs)

### Search Performance

Use Google Search Console MCP for:
- Query performance data
- Click-through rates
- Position tracking
- Index coverage

See `seo/google-search-console.md` for query patterns.

### SERP Analysis

Use DataForSEO or Serper for real-time SERP data:
- **DataForSEO**: Comprehensive SERP data with keyword metrics
- **Serper**: Quick Google searches (web, images, news, places)

See `seo/dataforseo.md` and `seo/serper.md` for usage.

### Keyword Research (Legacy)

Combine tools:
- GSC for existing performance
- DataForSEO for keyword data (volume, CPC, difficulty)
- Ahrefs for competitor analysis
- Content gap identification

### Backlink Analysis

- **DataForSEO**: Backlink data, referring domains, anchor text
- **Ahrefs**: Comprehensive backlink profiles

### Technical SEO

- PageSpeed optimization (see `tools/browser/pagespeed.md`)
- Core Web Vitals monitoring
- Mobile usability
- Structured data validation
- On-page analysis (DataForSEO)
- **Site crawling**: Use `site-crawler.md` for comprehensive audits

### Site Auditing

Use `seo/site-crawler.md` for Screaming Frog-like capabilities:

```bash
# Full site crawl
site-crawler-helper.sh crawl https://example.com

# Specific audits
site-crawler-helper.sh audit-links https://example.com
site-crawler-helper.sh audit-meta https://example.com
site-crawler-helper.sh audit-redirects https://example.com
```

Output: `~/Downloads/{domain}/{datestamp}/` with CSV/XLSX reports.

### E-E-A-T Content Quality

Use `seo/eeat-score.md` for content quality analysis:

```bash
# Analyze crawled pages
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json

# Score single URL
eeat-score-helper.sh score https://example.com/article
```

Scores 7 criteria (1-10): Authorship, Citation, Effort, Originality, Intent, Subjective Quality, Writing.
Output: `{domain}-eeat-score-{date}.xlsx` with scores and reasoning.

### Sitemap Submission

Use `seo/gsc-sitemaps.md` for automated sitemap submissions:

```bash
# Submit sitemap for single domain
~/.aidevops/agents/scripts/gsc-sitemap-helper.sh submit example.com

# Submit for multiple domains
~/.aidevops/agents/scripts/gsc-sitemap-helper.sh submit example.com example.net example.org

# Submit from file
~/.aidevops/agents/scripts/gsc-sitemap-helper.sh submit --file domains.txt

# Check status
~/.aidevops/agents/scripts/gsc-sitemap-helper.sh status example.com
```

Uses Playwright browser automation with persistent Chrome profile. First-time setup requires `~/.aidevops/agents/scripts/gsc-sitemap-helper.sh login` to authenticate.

### Data Export & Opportunity Analysis

Export ranking data from multiple platforms and analyze for opportunities:

```bash
# Export from all platforms (GSC, Bing, Ahrefs, DataForSEO)
/seo-export all example.com --days 90

# Run full analysis
/seo-analyze example.com

# Or combine both in one step
/seo-opportunities example.com --days 90
```

**Analysis types**:
- **Quick Wins**: Position 4-20, high impressions (easy improvements)
- **Striking Distance**: Position 11-30, high volume (page 2 to page 1)
- **Low CTR**: High impressions, low clicks (title/meta optimization)
- **Cannibalization**: Same query ranking with multiple URLs

Output: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`

See `seo/data-export.md` and `seo/ranking-opportunities.md` for details.

### Content Optimization

Integrate with `content.md` for:
- Keyword-focused content creation
- Meta optimization
- Internal linking strategy

## Tool Comparison

| Feature | GSC | DataForSEO | Serper | Ahrefs |
|---------|-----|------------|--------|--------|
| Search Performance | Yes | No | No | No |
| SERP Data | No | Yes | Yes | Yes |
| Keyword Research | Limited | Yes | No | Yes |
| Backlinks | No | Yes | No | Yes |
| On-Page Analysis | No | Yes | No | Yes |
| Local/Places | No | Yes | Yes | No |
| News Search | No | Yes | Yes | No |
| Pricing | Free | Subscription | Pay-per-search | Subscription |

## Oh-My-OpenCode Integration

When oh-my-opencode is installed, leverage these specialized agents for enhanced SEO workflows:

| OmO Agent | When to Use | Example |
|-----------|-------------|---------|
| `@document-writer` | Content optimization, meta descriptions, SEO copywriting | "Ask @document-writer to optimize this article for 'keyword'" |
| `@librarian` | Research SEO best practices, find implementation examples | "Ask @librarian for schema markup examples" |
| `@multimodal-looker` | Analyze competitor screenshots, infographics | "Ask @multimodal-looker to analyze this competitor's page layout" |

**Content Optimization Workflow**:

```text
1. /keyword-research "topic" → identify targets
2. @document-writer → create optimized content
3. E-E-A-T analysis → validate quality
4. Technical SEO → implement schema, meta
```

**Note**: These agents require [oh-my-opencode](https://github.com/code-yeongyu/oh-my-opencode) plugin.
See `tools/opencode/oh-my-opencode.md` for installation.
