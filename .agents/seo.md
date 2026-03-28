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
  - geo-strategy
  - sro-grounding
  - query-fanout-research
  - ai-hallucination-defense
  - ai-agent-discovery
  - ai-search-readiness
  - general
  - explore
---

# SEO - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: SEO optimization and analysis
- **Tools**: Google Search Console, Ahrefs, Semrush, DataForSEO, Serper, PageSpeed Insights, Google Analytics, Context7
- **MCP**: GSC, DataForSEO, Serper, Google Analytics, Context7
- **Commands**: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/seo-export`, `/seo-analyze`, `/seo-opportunities`, `/seo-write`, `/seo-optimize`, `/seo-analyze-content`, `/seo-fanout`, `/seo-geo`, `/seo-sro`, `/seo-hallucination-defense`, `/seo-agent-discovery`, `/seo-ai-readiness`, `/seo-ai-baseline`

**Subagents** (`seo/` and `services/analytics/`):

| Subagent | Purpose |
|----------|---------|
| `keyword-research.md` | Keyword research with SERP weakness detection (17 types, KeywordScore 0-100) |
| `google-search-console.md` | GSC queries, search performance, index coverage |
| `gsc-sitemaps.md` | Sitemap submission via Playwright browser automation |
| `dataforseo.md` | SERP data, keywords, backlinks, on-page (REST API) |
| `serper.md` | Google Search API (web, images, news, places) |
| `ahrefs.md` | Backlinks, organic keywords, domain rating (REST API v3) |
| `semrush.md` | Domain analytics, keywords, backlinks, competitor research |
| `site-crawler.md` | Site auditing — links, meta, redirects (Screaming Frog-like) |
| `screaming-frog.md` | Screaming Frog SEO Spider CLI integration |
| `eeat-score.md` | E-E-A-T content quality scoring (7 criteria, 1-10) |
| `contentking.md` | Real-time SEO monitoring and change tracking |
| `ranking-opportunities.md` | Quick wins, striking distance, cannibalization analysis |
| `analytics-tracking.md` | GA4 setup, event tracking, conversions, UTM, attribution |
| `rich-results.md` | Google Rich Results Test via browser automation |
| `debug-opengraph.md` | Validate Open Graph meta tags |
| `debug-favicon.md` | Validate favicon setup across platforms |
| `programmatic-seo.md` | SEO pages at scale with templates and keyword clustering |
| `image-seo.md` | AI-powered alt text, filenames, tags (Moondream); upscaling via `upscale.md` |
| `content-analyzer.md` | Content analysis (readability, keywords, SEO quality) |
| `seo-optimizer.md` | On-page SEO audit with prioritized recommendations |
| `keyword-mapper.md` | Keyword placement, density, and distribution analysis |
| `geo-strategy.md` | AI search visibility — criteria extraction, retrieval-first optimization |
| `sro-grounding.md` | Selection Rate Optimization for grounding snippet coverage |
| `query-fanout-research.md` | Query decomposition and thematic fan-out for content planning |
| `ai-hallucination-defense.md` | Detect brand hallucination risk, consistency and claim-evidence audits |
| `ai-agent-discovery.md` | Validate autonomous agents can discover key site information |
| `ai-search-readiness.md` | End-to-end orchestration: fan-out → GEO → SRO → consistency → discoverability |
| `google-analytics.md` | GA4 reporting, traffic analysis, user behavior |
| `data-export.md` | Export SEO data from GSC, Bing, Ahrefs, DataForSEO to TOON format |

Each subagent has curl examples. Load the relevant one when needed.

**Content Analysis** (adapted from [SEO Machine](https://github.com/TheCraigHewitt/seomachine)):

```bash
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze article.md --keyword "target keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md --keyword "keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py intent "search query"
```

**Commands**:

```bash
/keyword-research "best seo tools, keyword research"
/autocomplete-research "how to lose weight"
/keyword-research-extended "dog training tips"
/keyword-research-extended --competitor petco.com
/keyword-research-extended --gap mysite.com,competitor.com
/seo-opportunities example.com --days 90

# AI search readiness
/seo-fanout "best personal injury lawyer chicago"
/seo-geo example.com
/seo-sro example.com
/seo-hallucination-defense example.com
/seo-agent-discovery example.com
/seo-ai-readiness example.com
/seo-ai-baseline example.com
```

**Testing**: Use OpenCode CLI to test SEO commands without restarting TUI:

```bash
opencode run "/keyword-research 'test query'" --agent SEO
```

See `tools/opencode/opencode.md` for CLI testing patterns.

<!-- AI-CONTEXT-END -->

## SEO Workflow

### Keyword Research

```bash
/keyword-research "seed keywords"           # Expand seed keywords
/autocomplete-research "question phrase"    # Long-tail discovery
/keyword-research-extended "top keywords"   # Full SERP analysis with weakness detection
```

See `seo/keyword-research.md` for Domain/Competitor/Gap research modes and provider configuration.

### Search Performance

Use Google Search Console MCP for query performance, CTR, position tracking, and index coverage. See `seo/google-search-console.md`.

### AI Search Optimization (GEO and SRO)

Retrieval-first workflow for AI search surfaces:

0. `/seo-ai-baseline example.com` — capture grounding eligibility, coverage, selection, integrity, discoverability baselines
1. `/seo-fanout "target query"` — model thematic sub-queries (`seo/query-fanout-research.md`)
2. `/seo-geo example.com` — extract decision criteria, map coverage gaps (`seo/geo-strategy.md`)
3. `/seo-sro example.com` — improve snippet selection and grounding density (`seo/sro-grounding.md`)
4. `/seo-hallucination-defense example.com` — remove contradictions and unsupported claims (`seo/ai-hallucination-defense.md`)
5. `/seo-agent-discovery example.com` — validate autonomous agents can find key information (`seo/ai-agent-discovery.md`)

Focus: deterministic retrieval signals (content clarity, structure, consistency, discoverability). Full scorecard: `seo/ai-search-readiness.md`.

### SERP and Backlink Analysis

- **SERP**: DataForSEO (comprehensive + keyword metrics) or Serper (quick searches). See `seo/dataforseo.md`, `seo/serper.md`.
- **Backlinks**: DataForSEO (referring domains, anchor text) or Ahrefs (full profiles). See `seo/ahrefs.md`.

### Technical SEO

- PageSpeed / Core Web Vitals (`tools/browser/pagespeed.md`)
- Mobile usability, structured data validation, on-page analysis (DataForSEO)
- Site crawling: `seo/site-crawler.md`
- Real-time monitoring: `seo/contentking.md`

### Site Auditing

```bash
site-crawler-helper.sh crawl https://example.com
site-crawler-helper.sh audit-links https://example.com
site-crawler-helper.sh audit-meta https://example.com
site-crawler-helper.sh audit-redirects https://example.com
```

Output: `~/Downloads/{domain}/{datestamp}/` with CSV/XLSX reports.

### E-E-A-T Content Quality

```bash
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json
eeat-score-helper.sh score https://example.com/article
```

Scores 7 criteria (1-10): Authorship, Citation, Effort, Originality, Intent, Subjective Quality, Writing.
Output: `{domain}-eeat-score-{date}.xlsx`.

### Sitemap Submission

```bash
~/.aidevops/agents/scripts/gsc-sitemap-helper.sh submit example.com
~/.aidevops/agents/scripts/gsc-sitemap-helper.sh submit example.com example.net example.org
~/.aidevops/agents/scripts/gsc-sitemap-helper.sh submit --file domains.txt
~/.aidevops/agents/scripts/gsc-sitemap-helper.sh status example.com
```

Uses Playwright with persistent Chrome profile. First-time: `gsc-sitemap-helper.sh login`.

### Data Export & Opportunity Analysis

```bash
/seo-export all example.com --days 90   # Export from GSC, Bing, Ahrefs, DataForSEO
/seo-analyze example.com                # Analyze for opportunities
/seo-opportunities example.com --days 90  # Both in one step
```

**Analysis types**: Quick Wins (pos 4-20), Striking Distance (pos 11-30), Low CTR, Cannibalization.
Output: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`. See `seo/data-export.md`, `seo/ranking-opportunities.md`.

### Image SEO

AI-powered via `seo/image-seo.md`: alt text (WCAG-compliant, Moondream), SEO filenames, keyword tags, quality upscaling. See `seo/moondream.md`, `seo/upscale.md`.

### Content Optimization

Integrate with `content.md`: content calendar (`content/content-calendar.md`), SEO writing (`content/seo-writer.md`), meta generation (`content/meta-creator.md`), internal linking (`content/internal-linker.md`), editing (`content/editor.md`).

Workflow: Plan → Research (`/keyword-research`) → Write → Analyze (`seo-content-analyzer.py`) → Optimize (`seo/seo-optimizer.md`) → Edit → Publish.

Per-project SEO config: see `content/context-templates.md` for brand voice, style guide, keyword, and competitor templates.

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
