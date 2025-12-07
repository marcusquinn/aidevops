# SEO - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: SEO optimization and analysis
- **Tools**: Google Search Console, Ahrefs, DataForSEO, Serper, PageSpeed Insights
- **MCP**: GSC, DataForSEO, Serper for comprehensive SEO data

**Subagents** (`seo/`):

| Subagent | Purpose |
|----------|---------|
| `google-search-console.md` | GSC queries and search performance |
| `dataforseo.md` | Comprehensive SEO data APIs (SERP, keywords, backlinks) |
| `serper.md` | Google Search API (web, images, news, places) |

**Key Operations**:
- Search performance analysis (GSC)
- SERP analysis (DataForSEO, Serper)
- Keyword research (DataForSEO)
- Backlink analysis (Ahrefs, DataForSEO)
- Page speed optimization (PageSpeed)
- Content optimization

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

<!-- AI-CONTEXT-END -->

## SEO Workflow

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

### Keyword Research

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
