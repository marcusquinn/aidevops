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

- **Research**: `keyword-research` (SERP weakness, 17 types, KeywordScore 0-100) | `ranking-opportunities` (quick wins, striking distance, cannibalization) | `query-fanout-research` (thematic fan-out) | `keyword-mapper` (placement/density) | `domain-research`
- **Data providers**: `google-search-console` (queries, performance, index) | `dataforseo` (SERP, keywords, backlinks, on-page REST API) | `serper` (Google Search API) | `ahrefs` (backlinks, DR, REST API v3) | `semrush` (domain analytics, competitor research)
- **Analytics**: `google-analytics` (GA4 reporting) | `analytics-tracking` (GA4 setup, events, UTM, attribution)
- **Technical**: `site-crawler` (links, meta, redirects) | `screaming-frog` (SEO Spider CLI) | `contentking` (real-time monitoring) | `pagespeed`
- **Content**: `content-analyzer` (readability, keywords, quality) | `seo-optimizer` (on-page audit) | `eeat-score` (7 criteria, 1-10) | `programmatic-seo` (pages at scale)
- **AI search**: `geo-strategy` (criteria extraction, retrieval-first) | `sro-grounding` (snippet selection) | `ai-hallucination-defense` (claim-evidence audits) | `ai-agent-discovery` (discoverability) | `ai-search-readiness` (end-to-end orchestration)
- **Media/debug**: `image-seo` (alt text, Moondream) | `upscale` | `moondream` | `rich-results` (browser automation) | `debug-opengraph` | `debug-favicon`
- **Export**: `data-export` (GSC, Bing, Ahrefs, DataForSEO → TOON) | `gsc-sitemaps` (Playwright submission)

**Content analysis** ([SEO Machine](https://github.com/TheCraigHewitt/seomachine)): `python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py {analyze|readability|keywords|quality|intent} <file|query> [--keyword "kw"]`

**Testing**: `opencode run "/keyword-research 'test query'" --agent SEO` (see `tools/opencode/opencode.md`).

<!-- AI-CONTEXT-END -->

## SEO Workflow

### Keyword Research

`/keyword-research "seed keywords"` | `/autocomplete-research "question"` | `/keyword-research-extended "top keywords"`. See `seo/keyword-research.md` for Domain/Competitor/Gap modes. GSC MCP for query performance, CTR, position tracking, index coverage (`seo/google-search-console.md`).

### AI Search Optimization (GEO and SRO)

Retrieval-first workflow: baseline → fanout → GEO → SRO → hallucination defense → agent discovery. Focus: deterministic retrieval signals (content clarity, structure, consistency, discoverability). Full scorecard: `seo/ai-search-readiness.md`.

### SERP, Backlinks, and Technical SEO

- **SERP**: DataForSEO (comprehensive) or Serper (quick) | **Backlinks**: DataForSEO or Ahrefs
- **PageSpeed / CWV**: `tools/browser/pagespeed.md` | **On-page**: DataForSEO
- **Site crawling**: `seo/site-crawler.md` | **Real-time monitoring**: `seo/contentking.md`

### Site Auditing

```bash
site-crawler-helper.sh {crawl|audit-links|audit-meta|audit-redirects} https://example.com
```

Output: `~/Downloads/{domain}/{datestamp}/` (CSV/XLSX).

### E-E-A-T Content Quality

```bash
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json
eeat-score-helper.sh score https://example.com/article
```

Scores 7 criteria (1-10): Authorship, Citation, Effort, Originality, Intent, Subjective Quality, Writing. Output: `{domain}-eeat-score-{date}.xlsx`.

### Sitemap Submission

```bash
gsc-sitemap-helper.sh submit example.com [example.net ...]  # or --file domains.txt
gsc-sitemap-helper.sh status example.com
```

Uses Playwright with persistent Chrome profile. First-time: `gsc-sitemap-helper.sh login`. Full path: `~/.aidevops/agents/scripts/gsc-sitemap-helper.sh`.

### Data Export, Image SEO, and Content Optimization

- **Opportunities**: Quick Wins (pos 4-20), Striking Distance (pos 11-30), Low CTR, Cannibalization. Output: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`.
- **Image SEO**: AI-powered alt text (WCAG-compliant, Moondream), SEO filenames, keyword tags, upscaling. See `seo/image-seo.md`.
- **Content**: Integrate with `content.md` (calendar, SEO writing, meta, internal linking, editing). Per-project config: `content/context-templates.md`. Workflow: Plan → Research → Write → Analyze → Optimize (`seo/seo-optimizer.md`) → Edit → Publish.

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
