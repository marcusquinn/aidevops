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
- **Related**: `keyword-research.md`, `site-crawler.md`, `eeat-score.md`, `schema-markup`, `ranking-opportunities.md`, `google-search-console.md`
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

Run `/keyword-research-extended "seed keyword"`. Cluster signals: same head term + varying modifier, consistent volume across variations, similar SERP intent, low keyword difficulty.

### 2. Template Design

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
- Each page MUST have unique, substantive content — not just variable substitution
- Minimum 300 words of unique content per page; include real data points per variation
- Add genuine value beyond what a single parent page could provide

### 3. Data Collection

| Source Type | Examples | Method |
|-------------|----------|--------|
| Public APIs | Census data, weather, pricing | API calls via bash/scripts |
| Scraped data | Competitor features, reviews | `crawl4ai`, `site-crawler` |
| Internal data | Product specs, integrations | Database/CMS export |
| Keyword data | Search volume, questions | DataForSEO, Serper |
| AI-generated | Unique descriptions, summaries | LLM with factual grounding |

### 4. Page Generation

```text
For each {modifier} in data_source:
  1. Populate template variables
  2. Generate unique content sections (AI-assisted with data grounding)
  3. Build internal links to related pages in the cluster
  4. Generate structured data (JSON-LD)
  5. Create meta tags (title, description, canonical)
  6. Validate: word count, uniqueness, E-E-A-T signals
```

| Platform | Method |
|----------|--------|
| WordPress | Custom post type + ACF/SCF fields + template |
| Next.js/Nuxt | Dynamic routes + `getStaticPaths` + data files |
| Static site | Build script generating HTML/MD from data |
| Headless CMS | API-driven content creation |

### 5. Internal Linking

- **Hub and spoke**: Parent category page links to all variations; hub links all children (paginated if >50)
- **Cross-linking**: Related variations link to each other (same region, same category)
- **Breadcrumbs**: Clear hierarchy (Home > Category > Variation)
- **Footer/sidebar**: "Related {type}" blocks with 5–10 contextual links
- **Sitemap**: Dedicated XML sitemap for the programmatic section
- Each page: 3–10 internal links to cluster pages; avoid all-to-all linking (dilutes link equity)

### 6. Quality Assurance

**Technical**:
- [ ] All URLs resolve (no 404s)
- [ ] Canonical tags point to self
- [ ] No duplicate title tags or meta descriptions
- [ ] Structured data validates (`rich-results.md`)
- [ ] Pages in XML sitemap; robots.txt allows crawling
- [ ] Page load time <3s (`pagespeed.md`)

**Content**:
- [ ] Each page has >300 words of unique content
- [ ] No duplicate content across variations (`site-crawler`)
- [ ] Data is accurate and current; grammar and readability pass
- [ ] E-E-A-T signals present (`eeat-score.md`)

**SEO**:
- [ ] Target keyword in title, H1, and first paragraph
- [ ] Internal links use descriptive anchor text
- [ ] Images have alt text with relevant keywords
- [ ] Schema markup matches page type

## Anti-Patterns

| Anti-Pattern | Why It Fails | Better Approach |
|--------------|-------------|-----------------|
| Variable-only pages | Thin content penalty | Add unique data/content per page |
| Thousands of near-identical pages | Crawl budget waste, deindexing | Only create pages with genuine unique value |
| No internal linking | Orphan pages, poor crawlability | Hub-and-spoke + cross-linking |
| Ignoring search intent | High bounce rate, no rankings | Match template to user intent |
| Stale data | Inaccurate pages lose trust | Schedule data refresh cycles |
| Over-optimization | Keyword stuffing penalties | Write for users, optimize for search |

## When to Use pSEO

**Use**: 50+ keyword variations with consistent intent, unique data per variation, clear user value per page.

**Don't use**: <20 variations (write individual pages), no unique data per variation (consolidate), variations have no search volume.

**Post-launch monitoring**: Track indexation via GSC (`google-search-console.md`); monitor soft 404s and crawl errors; check ranking progress per cluster; watch for cannibalization (`ranking-opportunities.md`); review engagement metrics.
