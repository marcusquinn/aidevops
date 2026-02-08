---
description: Content calendar planning with AI-powered gap analysis and lifecycle tracking
mode: subagent
tools:
  read: true
  write: true
  bash: true
---

# Content Calendar Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Plan, schedule, and track content across platforms with AI-driven topic discovery
- **Workflow**: Gap analysis -> topic clustering -> calendar planning -> lifecycle tracking
- **Related**: `seo/keyword-research.md`, `seo/google-search-console.md`, `tools/content/guidelines.md`
- **Calendar file**: `TODO.md` or `todo/content-calendar.md` (markdown-based, task-compatible)

## Content Gap Analysis

Use keyword research data to identify missing coverage:

1. **Export GSC data**: Pull queries from `google-search-console.md` (impressions without clicks = gap)
2. **Cluster keywords**: Group by parent topic using `keyword-research.md` SERP similarity
3. **Audit existing content**: Map published URLs to keyword clusters, flag uncovered clusters
4. **Competitor gap**: Compare covered topics against competitor sitemaps/rankings
5. **Prioritize**: Score by `search_volume * (1 - current_coverage) * business_relevance`

```bash
# Extract high-impression, low-CTR queries as content gaps (see seo/google-search-console.md)
gsc-helper.sh query-report --min-impressions 500 --max-ctr 0.02 --days 90
```

## Topic Suggestions & Clustering

Organize topics into **pillars** (broad authority pages) and **clusters** (supporting articles):

| Layer | Type | Example | Word Count |
|-------|------|---------|------------|
| Pillar | Comprehensive guide | "Complete Guide to CI/CD" | 3000-5000 |
| Cluster | Supporting article | "GitHub Actions vs GitLab CI" | 1500-2500 |
| Satellite | Quick reference | "Docker Compose Cheatsheet" | 500-1000 |

**Search intent mapping**: Assign each topic an intent to guide format:

| Intent | Format | CTA |
|--------|--------|-----|
| Informational | How-to, guide, explainer | Newsletter, related post |
| Commercial | Comparison, review, "best X" | Free trial, demo |
| Transactional | Landing page, pricing | Purchase, sign up |
| Navigational | Documentation, FAQ | Product link, support |

## Calendar Structure

```markdown
## Week of YYYY-MM-DD

- [ ] MON: Draft "Topic A" (cluster: CI/CD) @author #blog ~3h
- [ ] WED: Publish "Topic A" + social adapts @editor #publish
- [ ] THU: LinkedIn post (Topic A excerpt) @social #linkedin
- [ ] FRI: X thread (Topic A key points) @social #twitter
```

**Monthly overview**:

| Week | Pillar Focus | Blog | Social | Video | Email |
|------|-------------|------|--------|-------|-------|
| 1 | DevOps | Publish 1 | 3 posts | - | Newsletter |
| 2 | AI/ML | Publish 1 | 3 posts | 1 short | - |
| 3 | Security | Publish 1 | 3 posts | - | Newsletter |
| 4 | Community | Publish 1 | 3 posts | 1 long | Monthly recap |

Rotate pillar focus monthly. Maintain 2:1 ratio of cluster-to-pillar content.

## Content Lifecycle: `ideation -> draft -> review -> publish -> promote -> analyze`

| Stage | Duration | Exit Criteria |
|-------|----------|---------------|
| `#ideation` | 1-2 days | Keyword assigned, outline approved |
| `#draft` | 2-5 days | First draft complete, meets word count |
| `#review` | 1-2 days | SEO check, brand voice, fact-check |
| `#publish` | 1 day | Live URL, schema markup, internal links |
| `#promote` | 5-7 days | Cross-platform adapts posted (see guidelines.md) |
| `#analyze` | 14-30 days | GSC impressions/clicks, engagement metrics |

**Task format** (TODO.md compatible):

```markdown
- [ ] t101 "CI/CD Pipeline Guide" @marcus #draft ~4h pillar:devops started:2025-01-15
- [x] t102 "Docker vs Podman" @marcus #publish ~2h cluster:containers done:2025-01-18
```

## Platform Scheduling

Optimal posting windows (adjust per audience analytics):

| Platform | Best Days | Times (UTC) | Frequency |
|----------|-----------|------------|-----------|
| Blog | Tue-Thu | 09:00-11:00 | 1-2/week |
| LinkedIn | Tue-Thu | 07:00-08:30 | 3-5/week |
| X/Twitter | Mon-Fri | 12:00-15:00 | 1-3/day |
| YouTube | Thu-Sat | 14:00-16:00 | 1-2/week |
| Instagram | Mon, Wed, Fri | 11:00-13:00 | 3-5/week |
| Newsletter | Tue or Thu | 10:00 | 1-2/month |

**Stagger rule**: Blog publishes first. Social adaptations follow over 5-7 days per `guidelines.md` repurposing workflow.

## Content Pillars Strategy

Define 3-5 pillars that map to business goals. Every cluster links to its pillar; pillars link to all children. Cross-link related clusters (3-5 internal links per post). Update pillar pages quarterly.

```text
Pillar: "DevOps Automation"
├── Cluster: CI/CD pipelines (8 articles)
├── Cluster: Infrastructure as Code (6 articles)
├── Cluster: Monitoring & Observability (5 articles)
└── Cluster: Security & Compliance (4 articles)
```

## Integration Points

| Tool | Purpose | Command/Reference |
|------|---------|-------------------|
| Keyword Research | Topic discovery, volume data | `seo/keyword-research.md` |
| GSC | Performance tracking, gap detection | `seo/google-search-console.md` |
| Content Guidelines | Platform voice and format specs | `tools/content/guidelines.md` |
| TODO.md | Task tracking integration | Root `TODO.md` with `#content` tag |

<!-- AI-CONTEXT-END -->
