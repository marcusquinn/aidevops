---
description: "When the user wants to build SEO pages at scale using templates, keyword clustering, or automated page generation. Also use when the user mentions \"programmatic SEO,\" \"pSEO,\" \"template pages,\" \"landing page generation,\" \"keyword clustering for pages,\" \"city pages,\" \"comparison pages,\" or \"building pages at scale.\""
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Programmatic SEO - Page Generation at Scale

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build SEO-optimized pages at scale using templates, keyword clustering, and automated generation
- **Related**: `keyword-research.md` (keyword data), `site-crawler.md` (auditing), `eeat-score.md` (quality), `schema-markup` (structured data)
- **Input**: Keyword lists, data sources, page templates
- **Output**: Template definitions, page content, internal linking maps, sitemap entries

**Common pSEO page types**:

| Type | Example | Data Source |
|------|---------|-------------|
| Location pages | `/plumber-in-{city}` | City/region database |
| Comparison pages | `/{tool-a}-vs-{tool-b}` | Product/tool database |
| Glossary/definition | `/what-is-{term}` | Industry terms list |
| Integration pages | `/{product}-{integration}` | Integration catalog |
| Stats/data pages | `/{topic}-statistics-{year}` | Public datasets |
| Use case pages | `/{product}-for-{use-case}` | Use case taxonomy |
| Alternative pages | `/{competitor}-alternatives` | Competitor list |

<!-- AI-CONTEXT-END -->

## Workflow

### 1. Keyword Research and Clustering

Start with keyword data to identify scalable patterns:

```bash
# Discover keyword clusters
/keyword-research-extended "seed keyword"

# Look for repeating modifiers (city names, "vs", "alternative to", etc.)
# Group keywords by intent pattern
```

**Cluster identification signals**:

- Same head term + varying modifier (location, brand, feature)
- Consistent search volume across variations
- Similar SERP intent (informational, commercial, transactional)
- Low keyword difficulty across the cluster

### 2. Template Design

Define a page template with variable slots and static content sections:

**Template structure**:

```text
URL pattern:    /{head-term}-{modifier}
Title:          {Head Term} {Modifier} - {Unique Value Prop} | {Brand}
H1:             {Head Term} in {Modifier}
Meta desc:      {Dynamic summary using head term + modifier + CTA}

Sections:
  1. Introduction       (template + dynamic)
  2. Key data/stats     (data-driven, unique per page)
  3. Detailed content   (template + dynamic paragraphs)
  4. FAQ                (keyword-derived questions)
  5. Related pages      (internal linking block)
  6. CTA                (static or segment-specific)
```

**Quality requirements** (avoid thin content penalties):

- Each page MUST have unique, substantive content (not just variable substitution)
- Include real data points specific to each variation
- Minimum 300 words of unique content per page
- Add genuine value beyond what a single parent page could provide
- Include user-generated content, reviews, or real data where possible

### 3. Data Collection

Gather the data that populates each page variation:

| Source Type | Examples | Method |
|-------------|----------|--------|
| Public APIs | Census data, weather, pricing | API calls via bash/scripts |
| Scraped data | Competitor features, reviews | `crawl4ai`, `site-crawler` |
| Internal data | Product specs, integrations | Database/CMS export |
| Keyword data | Search volume, questions | DataForSEO, Serper |
| AI-generated | Unique descriptions, summaries | LLM with factual grounding |

### 4. Page Generation

Generate pages from template + data:

```text
For each {modifier} in data_source:
  1. Populate template variables
  2. Generate unique content sections (AI-assisted with data grounding)
  3. Build internal links to related pages in the cluster
  4. Generate structured data (JSON-LD)
  5. Create meta tags (title, description, canonical)
  6. Validate: word count, uniqueness, E-E-A-T signals
```

**Implementation approaches by platform**:

| Platform | Method |
|----------|--------|
| WordPress | Custom post type + ACF/SCF fields + template |
| Next.js/Nuxt | Dynamic routes + `getStaticPaths` + data files |
| Static site | Build script generating HTML/MD from data |
| Headless CMS | API-driven content creation |

### 5. Internal Linking

Programmatic pages need strong internal linking to avoid orphan pages:

**Linking strategies**:

- **Hub and spoke**: Parent category page links to all variations
- **Cross-linking**: Related variations link to each other (same region, same category)
- **Breadcrumbs**: Clear hierarchy (Home > Category > Variation)
- **Footer/sidebar**: "Related {type}" blocks with 5-10 contextual links
- **Sitemap**: Dedicated XML sitemap for the programmatic section

**Link volume guidelines**:

- Each page should have 3-10 internal links to other pages in the cluster
- Hub page should link to all child pages (paginated if >50)
- Avoid linking to every page from every page (dilutes link equity)

### 6. Quality Assurance

Before launching, validate the generated pages:

**Technical checks**:

- [ ] All URLs resolve (no 404s)
- [ ] Canonical tags point to self
- [ ] No duplicate title tags or meta descriptions
- [ ] Structured data validates (use `rich-results.md`)
- [ ] Pages are in XML sitemap
- [ ] Robots.txt allows crawling
- [ ] Page load time <3s (use `pagespeed.md`)

**Content checks**:

- [ ] Each page has >300 words of unique content
- [ ] No duplicate content across variations (check with site-crawler)
- [ ] Data is accurate and current
- [ ] Grammar and readability pass
- [ ] E-E-A-T signals present (use `eeat-score.md`)

**SEO checks**:

- [ ] Target keyword in title, H1, and first paragraph
- [ ] Internal links use descriptive anchor text
- [ ] Images have alt text with relevant keywords
- [ ] Schema markup matches page type

## Anti-Patterns to Avoid

| Anti-Pattern | Why It Fails | Better Approach |
|--------------|-------------|-----------------|
| Variable-only pages | Thin content penalty | Add unique data/content per page |
| Thousands of near-identical pages | Crawl budget waste, deindexing | Only create pages with genuine unique value |
| No internal linking | Orphan pages, poor crawlability | Hub-and-spoke + cross-linking |
| Ignoring search intent | High bounce rate, no rankings | Match template to user intent |
| Stale data | Inaccurate pages lose trust | Schedule data refresh cycles |
| Over-optimization | Keyword stuffing penalties | Write for users, optimize for search |

## Scaling Considerations

**When to use pSEO**:

- 50+ keyword variations with consistent intent
- Unique data available for each variation
- Clear user value per page (not just SEO play)

**When NOT to use pSEO**:

- <20 variations (write individual pages instead)
- No unique data per variation (consolidate into one page)
- Variations don't have search volume (no demand)

**Monitoring after launch**:

- Track indexation rate via GSC (use `google-search-console.md`)
- Monitor for soft 404s and crawl errors
- Check ranking progress per cluster
- Watch for cannibalization between variations (use `ranking-opportunities.md`)
- Review engagement metrics (bounce rate, time on page)

## Related Subagents

- **keyword-research**: Discover and cluster keywords for pSEO campaigns
- **site-crawler**: Audit generated pages for technical issues
- **eeat-score**: Validate content quality across generated pages
- **schema-markup**: Implement structured data for page types
- **ranking-opportunities**: Monitor ranking progress and cannibalization
- **google-search-console**: Track indexation and search performance
- **page-cro**: Optimize generated pages for conversion
