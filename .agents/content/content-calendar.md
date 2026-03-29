---
description: Content calendar planning with cadence engine, gap analysis, and lifecycle tracking
mode: subagent
tools:
  read: true
  write: true
  bash: true
---

# Content Calendar & Posting Cadence Engine

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Plan, schedule, and track content across platforms with cadence tracking and gap analysis
- **Helper**: `content-calendar-helper.sh` (SQLite-backed calendar with cadence engine)
- **Workflow**: Gap analysis -> topic clustering -> calendar planning -> cadence tracking -> lifecycle management
- **Related**: `content/optimization.md`, `content/distribution-*.md`, `seo/keyword-research.md`, `seo/google-search-console.md`

```bash
content-calendar-helper.sh add "Topic Title" --pillar DevOps --cluster "CI/CD" --intent commercial --author marcus
content-calendar-helper.sh schedule 1 2026-02-15 blog --time 10:00
content-calendar-helper.sh cadence [--platform youtube] [--weeks 8]  # actual vs target, UNDER/ON TRACK/OVER
content-calendar-helper.sh gaps --days 30                             # platform coverage, pillar distribution, empty days
content-calendar-helper.sh advance 1 [draft|review|publish|promote|analyze]
content-calendar-helper.sh list [--stage draft] [--platform youtube]
content-calendar-helper.sh due --days 7
content-calendar-helper.sh stats
content-calendar-helper.sh export --format [json|csv]
```

<!-- AI-CONTEXT-END -->

## Cadence Targets (posts/week)

| Platform | Min | Max | Optimal | Rationale |
|----------|-----|-----|---------|-----------|
| Blog | 1 | 2 | 1 | SEO favors depth over frequency |
| YouTube | 2 | 3 | 2 | Algorithm favors consistency |
| Shorts/TikTok/Reels | 5 | 7 | 7 | High volume needed for viral discovery |
| LinkedIn | 3 | 5 | 5 | Engagement requires daily presence |
| X/Twitter | 7 | 21 | 14 | 2-3 posts/day for visibility |
| Reddit | 2 | 3 | 2 | Community-native, quality over quantity |
| Email | 0.5 | 1 | 1 | Weekly to avoid list fatigue |
| Podcast | 0.5 | 1 | 1 | Weekly or bi-weekly |
| Instagram | 3 | 5 | 3 | Consistent visual presence |

## Optimal Posting Windows (UTC)

| Platform | Best Days | Times (UTC) |
|----------|-----------|-------------|
| Blog | Tue-Thu | 09:00-11:00 |
| YouTube | Thu-Sat | 14:00-16:00 |
| Shorts/TikTok | Mon-Fri | 12:00-15:00 |
| Reels/Instagram | Mon, Wed, Fri | 11:00-13:00 |
| LinkedIn | Tue-Thu | 07:00-08:30 |
| X/Twitter | Mon-Fri | 12:00-15:00 |
| Reddit | Mon-Fri | 09:00-11:00 |
| Email | Tue, Thu | 10:00 |

**Stagger rule**: Blog publishes first. Social adaptations follow over 5-7 days per `content/guidelines.md`.

## Content Gap Analysis

**Automated**: `content-calendar-helper.sh gaps --days 30`

**SEO-driven**:
1. Export GSC data: `gsc-helper.sh query-report --min-impressions 500 --max-ctr 0.02 --days 90` (high-impression, low-CTR = gap)
2. Cluster keywords by parent topic (`seo/keyword-research.md` SERP similarity)
3. Map published URLs to clusters; flag uncovered clusters
4. Competitor gap: compare covered topics against competitor sitemaps/rankings
5. Prioritize: `search_volume * (1 - current_coverage) * business_relevance`

## Topic Clustering

| Layer | Type | Example | Word Count |
|-------|------|---------|------------|
| Pillar | Comprehensive guide | "Complete Guide to CI/CD" | 3000-5000 |
| Cluster | Supporting article | "GitHub Actions vs GitLab CI" | 1500-2500 |
| Satellite | Quick reference | "Docker Compose Cheatsheet" | 500-1000 |

**Search intent mapping**:

| Intent | Format | CTA |
|--------|--------|-----|
| Informational | How-to, guide, explainer | Newsletter, related post |
| Commercial | Comparison, review, "best X" | Free trial, demo |
| Transactional | Landing page, pricing | Purchase, sign up |
| Navigational | Documentation, FAQ | Product link, support |

**Pillars strategy**: Define 3-5 pillars mapping to business goals. Every cluster links to its pillar. Cross-link related clusters (3-5 internal links per post). Update pillar pages quarterly. View distribution: `content-calendar-helper.sh stats`

## Calendar Structure

**Monthly overview** (rotate pillar focus monthly; maintain 2:1 cluster-to-pillar ratio):

| Week | Pillar Focus | Blog | Social | Video | Email |
|------|-------------|------|--------|-------|-------|
| 1 | DevOps | Publish 1 | 3 posts | - | Newsletter |
| 2 | AI/ML | Publish 1 | 3 posts | 1 short | - |
| 3 | Security | Publish 1 | 3 posts | - | Newsletter |
| 4 | Community | Publish 1 | 3 posts | 1 long | Monthly recap |

**Weekly task format**: `- [ ] MON: Draft "Topic A" (cluster: CI/CD) @author #blog ~3h`

**Multi-channel fan-out**: One story → multiple platforms over 5-7 days (diamond pipeline from `content.md`). Schedule with `content-calendar-helper.sh schedule <id> <date> <platform> [--time HH:MM]` following the stagger rule.

## Seasonality

| Quarter | Focus |
|---------|-------|
| Q4 (Oct-Dec) | Monetization content — reviews, comparisons, "best of" lists (highest buying intent) |
| Q1 (Jan-Mar) | Educational content — getting started guides, tutorials (New Year motivation) |
| Q2-Q3 (Apr-Sep) | Maintenance — test new formats, build Q4 backlog |

## Content Lifecycle

`ideation -> draft -> review -> publish -> promote -> analyze`

| Stage | Duration | Exit Criteria |
|-------|----------|---------------|
| `ideation` | 1-2 days | Keyword assigned, outline approved |
| `draft` | 2-5 days | First draft complete, meets word count |
| `review` | 1-2 days | SEO check, brand voice, fact-check |
| `publish` | 1 day | Live URL, schema markup, internal links |
| `promote` | 5-7 days | Cross-platform adapts posted |
| `analyze` | 14-30 days | GSC impressions/clicks, engagement metrics |

Advancing to `publish` auto-updates schedule entries to `published` and logs to cadence tracker.

## Integration Points

| Tool | Purpose | Reference |
|------|---------|-----------|
| Keyword Research | Topic discovery, volume data | `seo/keyword-research.md` |
| GSC | Performance tracking, gap detection | `seo/google-search-console.md` |
| Content Guidelines | Platform voice and format specs | `content/guidelines.md` |
| Content Optimization | A/B testing, analytics loops | `content/optimization.md` |
| Distribution Agents | Platform-specific publishing | `content/distribution-*.md` |
| TODO.md | Task tracking | Root `TODO.md` with `#content` tag |

## Analytics Feedback Loop

Publish → cadence analysis → gap analysis → update calendar → repeat.

```bash
content-calendar-helper.sh cadence --weeks 1   # last week performance
content-calendar-helper.sh gaps --days 7       # missing next week
content-calendar-helper.sh due --days 7        # upcoming items
content-calendar-helper.sh stats               # overall health
```
