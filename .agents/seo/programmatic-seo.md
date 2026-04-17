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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Programmatic SEO - Page Generation at Scale

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build SEO-optimized pages at scale via templates, keyword clustering, and automated generation
- **Related**: `keyword-research.md`, `site-crawler.md`, `eeat-score.md`, `schema-markup`, `ranking-opportunities.md`, `google-search-console.md`
- **Input**: Keyword lists, data sources, page templates
- **Output**: Template definitions, page content, internal linking maps, sitemap entries

**Common pSEO page types**:

| Type | Example | Data Source |
|------|---------|-------------|
| Location | `/plumber-in-{city}` | City/region database |
| Comparison | `/{tool-a}-vs-{tool-b}` | Product/tool database |
| Glossary | `/what-is-{term}` | Industry terms list |
| Integration | `/{product}-{integration}` | Integration catalog |
| Stats/data | `/{topic}-statistics-{year}` | Public datasets |
| Use case | `/{product}-for-{use-case}` | Use case taxonomy |
| Alternative | `/{competitor}-alternatives` | Competitor list |

<!-- AI-CONTEXT-END -->

## Workflow

### 1. Keyword Research and Clustering

Run `/keyword-research-extended "seed keyword"`. Cluster by: same head term + varying modifier, consistent volume, similar SERP intent, low difficulty.

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

**Quality gates** — each page MUST have unique, substantive content (not just variable substitution): ≥300 words unique content with real data points per variation; must add value beyond a single parent page.

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

- **Hub-and-spoke**: Parent category → all variations (paginated if >50)
- **Cross-linking**: Related variations link to each other (same region/category)
- **Breadcrumbs**: Home > Category > Variation
- **Footer/sidebar**: "Related {type}" blocks, 5-10 contextual links
- **Sitemap**: Dedicated XML sitemap for programmatic section
- Per page: 3-10 internal links to cluster pages; avoid all-to-all (dilutes equity)

### 6. Quality Assurance

**Technical**:
- All URLs resolve (no 404s); self-referencing canonicals; no duplicate titles/meta descriptions
- Structured data validates (`rich-results.md`); pages in XML sitemap; robots.txt allows crawling
- Load time <3s (`pagespeed.md`)

**Content**:
- >300 words unique per page; no duplicate content across variations (`site-crawler`)
- Accurate, current data; grammar/readability pass; E-E-A-T signals present (`eeat-score.md`)

**SEO**:
- Target keyword in title, H1, first paragraph
- Descriptive anchor text on internal links; image alt text with relevant keywords
- Schema markup matches page type

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

**Post-launch**: Track indexation via GSC (`google-search-console.md`); monitor soft 404s/crawl errors; ranking progress per cluster; watch for cannibalization (`ranking-opportunities.md`); review engagement metrics.

**Video content hubs at scale**: Use `seo/video-schema.md` to template `VideoObject` + `Clip` schema across large video libraries. Pair with `seo/transcript-seo.md` for per-page transcript embedding.
