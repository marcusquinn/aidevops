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
  - semrush
  - site-crawler
  - screaming-frog
  - eeat-score
  - contentking
  - domain-research
  - pagespeed
  - google-analytics
  - data-export
  - ranking-opportunities
  - analytics-tracking
  - rich-results
  - debug-opengraph
  - debug-favicon
  - programmatic-seo
  - image-seo
  - moondream
  - upscale
  - content-analyzer
  - seo-optimizer
  - keyword-mapper
  - general
  - explore
---

# SEO - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: SEO optimization and analysis
- **Tools**: Google Search Console, Ahrefs, Semrush, DataForSEO, Serper, PageSpeed Insights, Google Analytics, Context7
- **MCP**: GSC, DataForSEO, Serper, Google Analytics, Context7 for comprehensive SEO data and library docs
- **Commands**: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/seo-export`, `/seo-analyze`, `/seo-opportunities`, `/seo-write`, `/seo-optimize`, `/seo-analyze-content`

**Subagents** (`seo/` and `services/analytics/`):

| Subagent | Purpose |
|----------|---------|
| `keyword-research.md` | Comprehensive keyword research with SERP weakness detection |
| `google-search-console.md` | GSC queries and search performance |
| `gsc-sitemaps.md` | Sitemap submission via Playwright browser automation |
| `dataforseo.md` | Comprehensive SEO data APIs (SERP, keywords, backlinks) |
| `serper.md` | Google Search API (web, images, news, places) |
| `site-crawler.md` | SEO site auditing (Screaming Frog-like capabilities) |
| `screaming-frog.md` | Screaming Frog SEO Spider CLI integration |
| `eeat-score.md` | E-E-A-T content quality scoring and analysis |
| `google-analytics.md` | GA4 reporting, traffic analysis, and user behavior (see `services/analytics/`) |
| `data-export.md` | Export SEO data from GSC, Bing, Ahrefs, DataForSEO to TOON format |
| `semrush.md` | Semrush API - domain analytics, keyword research, competitor analysis |
| `contentking.md` | Conductor Monitoring (ContentKing) real-time SEO monitoring |
| `ranking-opportunities.md` | Analyze data for quick wins, striking distance, cannibalization |
| `analytics-tracking.md` | GA4 setup, event tracking, conversions, UTM parameters, attribution |
| `rich-results.md` | Google Rich Results Test via browser automation (API deprecated) |
| `debug-opengraph.md` | Validate Open Graph meta tags for social sharing |
| `debug-favicon.md` | Validate favicon setup across platforms |
| `programmatic-seo.md` | Build SEO pages at scale with templates and keyword clustering |
| `image-seo.md` | AI-powered image SEO: filename, alt text, tag generation |
| `moondream.md` | Moondream AI vision model for image analysis and captioning |
| `upscale.md` | Image upscaling services (Real-ESRGAN, Replicate, Cloudflare) |
| `content-analyzer.md` | Comprehensive content analysis (readability, keywords, SEO quality) |
| `seo-optimizer.md` | On-page SEO audit with prioritized recommendations |
| `keyword-mapper.md` | Keyword placement, density, and distribution analysis |

**Content Analysis** (adapted from [SEO Machine](https://github.com/TheCraigHewitt/seomachine)):

```bash
# Full content analysis with keyword
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze article.md --keyword "target keyword"

# Individual analyses
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md --keyword "keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py intent "search query"
```

**Key Operations**:
- Keyword research with weakness detection (`/keyword-research-extended`)
- Autocomplete long-tail expansion (`/autocomplete-research`)
- Competitor keyword analysis (`--competitor`)
- Keyword gap analysis (`--gap`)
- Search performance analysis (GSC)
- SERP analysis (DataForSEO, Serper)
- Backlink analysis (Ahrefs, DataForSEO)
- Page speed optimization (PageSpeed)
- **Image SEO**: AI-powered alt text, filename, and tag generation (`image-seo.md`)
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
| `semrush` | Semrush Analytics API v3 | Domain analytics, keywords, backlinks, competitor research |
| `contentking` | Conductor Monitoring API v2 | Real-time SEO monitoring, change tracking, issues |

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
- **Real-time monitoring**: Use `contentking.md` for 24/7 SEO monitoring and change tracking

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

### Image SEO

Use `seo/image-seo.md` for AI-powered image optimization:

- **Alt text generation**: WCAG-compliant descriptions via Moondream vision AI
- **SEO filenames**: Descriptive, hyphenated filenames from image content
- **Tag extraction**: Keyword tags for metadata and categorization
- **Quality upscaling**: Ensure minimum dimensions for social sharing

See `seo/image-seo.md` for the full workflow, `seo/moondream.md` for the vision API, and `seo/upscale.md` for upscaling options.

### Content Optimization

Integrate with `content.md` for:
- SEO-optimized content writing (`content/seo-writer.md`)
- Meta title/description generation (`content/meta-creator.md`)
- Internal linking strategy (`content/internal-linker.md`)
- Human voice editing (`content/editor.md`)

**Content analysis workflow** (from SEO Machine integration):

1. **Research**: `/keyword-research` + `/autocomplete-research`
2. **Write**: Use `content/seo-writer.md` with keyword targets
3. **Analyze**: `seo-content-analyzer.py analyze` for quality score
4. **Optimize**: Address issues from `seo/seo-optimizer.md`
5. **Edit**: `content/editor.md` for human voice
6. **Publish**: Via WordPress or CMS

**Context templates** for per-project SEO configuration:

See `content/context-templates.md` for brand voice, style guide, target keywords, internal links map, competitor analysis, and SEO guidelines templates. Create a `context/` directory in your project and populate from those templates.

## Tool Comparison

| Feature | GSC | DataForSEO | Serper | Ahrefs | Semrush |
|---------|-----|------------|--------|--------|---------|
| Search Performance | Yes | No | No | No | No |
| SERP Data | No | Yes | Yes | Yes | Yes |
| Keyword Research | Limited | Yes | No | Yes | Yes |
| Backlinks | No | Yes | No | Yes | Yes |
| On-Page Analysis | No | Yes | No | Yes | Yes (Site Audit) |
| Local/Places | No | Yes | Yes | No | No |
| News Search | No | Yes | Yes | No | No |
| Competitor Analysis | No | Yes | No | Yes | Yes (Domain vs Domain) |
| Position Tracking | No | No | No | No | Yes (Projects API) |
| Pricing | Free | Subscription | Pay-per-search | Subscription | Unit-based |
