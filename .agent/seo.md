# SEO - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: SEO optimization and analysis
- **Tools**: Google Search Console, Ahrefs, PageSpeed Insights
- **MCP**: GSC MCP for search performance data

**Subagents** (`seo/`):
- `google-search-console.md` - GSC queries and analysis

**Key Operations**:
- Search performance analysis
- Keyword research and tracking
- Backlink analysis (Ahrefs)
- Page speed optimization
- Content optimization

**MCP Integration**:
```bash
# GSC queries via MCP
gsc_search_analytics [site] [query]
gsc_index_status [site] [url]
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

### Keyword Research

Combine tools:
- GSC for existing performance
- Ahrefs for competitor analysis
- Content gap identification

### Technical SEO

- PageSpeed optimization (see `tools/browser/pagespeed.md`)
- Core Web Vitals monitoring
- Mobile usability
- Structured data validation

### Content Optimization

Integrate with `content.md` for:
- Keyword-focused content creation
- Meta optimization
- Internal linking strategy
