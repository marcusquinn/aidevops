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
- **Related**: `content/optimization.md`, `content/distribution/`, `seo/keyword-research.md`, `seo/google-search-console.md`

**Key Commands**:

```bash
# Add content to calendar
content-calendar-helper.sh add "Topic Title" --pillar DevOps --intent informational

# Schedule across platforms
content-calendar-helper.sh schedule 1 2026-02-15 blog --time 10:00
content-calendar-helper.sh schedule 1 2026-02-17 linkedin
content-calendar-helper.sh schedule 1 2026-02-17 x

# Check posting cadence
content-calendar-helper.sh cadence --platform youtube --weeks 8

# Find content gaps
content-calendar-helper.sh gaps --days 30

# Move through lifecycle
content-calendar-helper.sh advance 1 draft

# See what's due
content-calendar-helper.sh due --days 7
```

<!-- AI-CONTEXT-END -->

## Cadence Engine

The cadence engine tracks posting frequency per platform against evidence-based targets and recommends adjustments.

### Cadence Targets (posts/week)

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

**Cadence analysis**:

```bash
# Full cadence report across all platforms
content-calendar-helper.sh cadence

# Platform-specific with custom window
content-calendar-helper.sh cadence --platform youtube --weeks 8
```

Output shows actual vs target posting rate, gap, and recommendations (UNDER/ON TRACK/OVER).

### Optimal Posting Windows (UTC)

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

**Stagger rule**: Blog publishes first. Social adaptations follow over 5-7 days per `content/guidelines.md` repurposing workflow.

## Content Gap Analysis

### Automated Gap Detection

```bash
# Find gaps in the next 30 days
content-calendar-helper.sh gaps --days 30

# Shows:
# - Platform coverage vs targets
# - Pillar distribution
# - Empty weekdays with no content scheduled
```

### SEO-Driven Gap Analysis

Use keyword research data to identify missing coverage:

1. **Export GSC data**: Pull queries from `seo/google-search-console.md` (impressions without clicks = gap)
2. **Cluster keywords**: Group by parent topic using `seo/keyword-research.md` SERP similarity
3. **Audit existing content**: Map published URLs to keyword clusters, flag uncovered clusters
4. **Competitor gap**: Compare covered topics against competitor sitemaps/rankings
5. **Prioritize**: Score by `search_volume * (1 - current_coverage) * business_relevance`

```bash
# Extract high-impression, low-CTR queries as content gaps
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

```bash
# Add content with pillar, cluster, and intent
content-calendar-helper.sh add "GitHub Actions vs GitLab CI" \
  --pillar DevOps --cluster "CI/CD" --intent commercial --author marcus
```

## Calendar Structure

### Weekly View (Markdown)

```markdown
## Week of YYYY-MM-DD

- [ ] MON: Draft "Topic A" (cluster: CI/CD) @author #blog ~3h
- [ ] WED: Publish "Topic A" + social adapts @editor #publish
- [ ] THU: LinkedIn post (Topic A excerpt) @social #linkedin
- [ ] FRI: X thread (Topic A key points) @social #twitter
```

### Monthly Overview

| Week | Pillar Focus | Blog | Social | Video | Email |
|------|-------------|------|--------|-------|-------|
| 1 | DevOps | Publish 1 | 3 posts | - | Newsletter |
| 2 | AI/ML | Publish 1 | 3 posts | 1 short | - |
| 3 | Security | Publish 1 | 3 posts | - | Newsletter |
| 4 | Community | Publish 1 | 3 posts | 1 long | Monthly recap |

Rotate pillar focus monthly. Maintain 2:1 ratio of cluster-to-pillar content.

### Database-Backed Calendar

```bash
# List all items with schedule info
content-calendar-helper.sh list

# Filter by stage or platform
content-calendar-helper.sh list --stage draft
content-calendar-helper.sh list --platform youtube

# Export for external tools
content-calendar-helper.sh export --format json
content-calendar-helper.sh export --format csv
```

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

```bash
# Move item through stages
content-calendar-helper.sh advance 1 draft
content-calendar-helper.sh advance 1 review
content-calendar-helper.sh advance 1 publish  # Auto-logs to cadence tracker

# Check item details and schedule
content-calendar-helper.sh status 1
```

When advancing to `publish`, the helper automatically:

- Updates schedule entries to `published` status
- Logs the publication to the cadence tracker
- Enables accurate cadence analysis going forward

## Content Pillars Strategy

Define 3-5 pillars that map to business goals. Every cluster links to its pillar; pillars link to all children. Cross-link related clusters (3-5 internal links per post). Update pillar pages quarterly.

```text
Pillar: "DevOps Automation"
├── Cluster: CI/CD pipelines (8 articles)
├── Cluster: Infrastructure as Code (6 articles)
├── Cluster: Monitoring & Observability (5 articles)
└── Cluster: Security & Compliance (4 articles)
```

```bash
# View pillar distribution
content-calendar-helper.sh stats
```

## Multi-Channel Fan-Out Workflow

When a content item is ready, schedule it across multiple platforms following the stagger rule:

```bash
# Day 1: Blog publish
content-calendar-helper.sh schedule 1 2026-02-15 blog --time 10:00

# Day 1-2: Social teasers
content-calendar-helper.sh schedule 1 2026-02-15 x --time 14:00
content-calendar-helper.sh schedule 1 2026-02-16 linkedin --time 08:00

# Day 3-5: Extended distribution
content-calendar-helper.sh schedule 1 2026-02-17 reddit
content-calendar-helper.sh schedule 1 2026-02-18 email
content-calendar-helper.sh schedule 1 2026-02-19 youtube
```

This follows the diamond pipeline from `content.md`: one story -> multiple platforms over 5-7 days.

## Seasonality Awareness

From `content/optimization.md`:

- **Q4 (Oct-Dec)**: Highest buying intent — prioritize monetization content (reviews, comparisons, "best of" lists)
- **Q1 (Jan-Mar)**: New Year motivation — prioritize educational content (getting started guides, tutorials)
- **Q2-Q3 (Apr-Sep)**: Maintenance mode — test new formats, build content backlog for Q4

## Integration Points

| Tool | Purpose | Command/Reference |
|------|---------|-------------------|
| Content Calendar Helper | Calendar management, cadence tracking | `content-calendar-helper.sh` |
| Keyword Research | Topic discovery, volume data | `seo/keyword-research.md` |
| GSC | Performance tracking, gap detection | `seo/google-search-console.md` |
| Content Guidelines | Platform voice and format specs | `content/guidelines.md` |
| Content Optimization | A/B testing, analytics loops | `content/optimization.md` |
| Distribution Agents | Platform-specific publishing | `content/distribution/` |
| TODO.md | Task tracking integration | Root `TODO.md` with `#content` tag |

## Analytics Feedback Loop

The cadence engine closes the loop between publishing and planning:

1. **Publish content** -> cadence tracker logs the post
2. **Run cadence analysis** -> identify under/over-served platforms
3. **Run gap analysis** -> find empty days and missing pillars
4. **Update calendar** -> schedule new content to fill gaps
5. **Repeat** -> continuous optimization cycle

```bash
# Weekly review workflow
content-calendar-helper.sh cadence --weeks 1    # How did last week go?
content-calendar-helper.sh gaps --days 7        # What's missing next week?
content-calendar-helper.sh due --days 7         # What's coming up?
content-calendar-helper.sh stats                # Overall health check
```
