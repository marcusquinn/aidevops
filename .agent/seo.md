# SEO - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: SEO optimization and analysis
- **Tools**: Google Search Console, Ahrefs, DataForSEO, Serper, PageSpeed Insights, Context7
- **MCP**: GSC, DataForSEO, Serper, Context7 for comprehensive SEO data and library docs
- **Commands**: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`

**Subagents** (`seo/`):

| Subagent | Purpose |
|----------|---------|
| `keyword-research.md` | Comprehensive keyword research with SERP weakness detection |
| `google-search-console.md` | GSC queries and search performance |
| `dataforseo.md` | Comprehensive SEO data APIs (SERP, keywords, backlinks) |
| `serper.md` | Google Search API (web, images, news, places) |

**Key Operations**:
- Keyword research with weakness detection (`/keyword-research-extended`)
- Autocomplete long-tail expansion (`/autocomplete-research`)
- Competitor keyword analysis (`--competitor`)
- Keyword gap analysis (`--gap`)
- Search performance analysis (GSC)
- SERP analysis (DataForSEO, Serper)
- Backlink analysis (Ahrefs, DataForSEO)
- Page speed optimization (PageSpeed)

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
```

**MCP Integration**:

```bash
# GSC queries via MCP
gsc_search_analytics [site] [query]
gsc_index_status [site] [url]

# DataForSEO via MCP
dataforseo.serp [keyword] [location]
dataforseo.keywords_data [keywords]
dataforseo.backlinks [domain]

# Serper via MCP
serper.google_search [query]
serper.google_search_news [query]
```

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
