---
name: blog
description: Blog distribution - SEO-optimized articles from content pipeline assets
mode: subagent
model: sonnet
---

# Blog - SEO-Optimized Article Distribution

**Purpose**: Transform content pipeline assets into SEO-optimized blog articles (1,500–3,000 words).

**Critical Rules**:
- **Keyword-first** — every article targets a primary keyword with validated search volume
- **Human voice** — AI-generated content must pass through `content/humanise.md` and `content/editor.md`
- **Internal linking** — 3–5 internal links per article via `content/internal-linker.md`
- **Meta optimization** — title tag, meta description, OG tags via `content/meta-creator.md`
- **One sentence per paragraph** — per `content/guidelines.md`

## Article Types

| Type | Length | Target |
|------|--------|--------|
| **Pillar** | 2,000–3,000 words | High-volume keywords, link hubs |
| **Supporting** | 800–1,500 words | Long-tail keywords, link to pillar |
| **Listicle** | 1,000–2,000 words | "best", "top", "how to" keywords |

**Pillar structure**: Title (keyword-front, <60 chars) → Meta (150–160 chars) → Intro (100–150w) → TOC → H2/H3 body → Key takeaways → CTA → FAQ

**Supporting structure**: Title → Intro (50–100w) → 3–5 H2 sections → Internal link to pillar → CTA

**Listicle structure**: Number + keyword + year title → Selection criteria → Numbered H2 items → Comparison table → Verdict

**Example** (pillar from story "Why 95% of AI influencers fail"):

```text
Title: Why 95% of AI Influencers Fail (And How to Be in the 5%)
H2: The AI Content Gold Rush
H2: 5 Mistakes That Kill AI Influencer Careers
  H3: Mistake 1 - Chasing Tools Instead of Problems
  H3: Mistake 2 - Publishing Unedited AI Content
  H3: Mistake 3 - Ignoring Audience Research
  H3: Mistake 4 - No Testing or Optimization
  H3: Mistake 5 - One-Off Posts Instead of Systems
H2: What the Top 5% Do Differently
H2: Building Your AI Content System
H2: Key Takeaways / FAQ
```

## SEO Workflow

### 1. Keyword Research

```bash
keyword-research-helper.sh volume "AI video generation tools"
keyword-research-helper.sh related "AI video generation"
keyword-research-helper.sh difficulty "AI video generation tools"
```

| Factor | Target |
|--------|--------|
| Monthly volume | 500+ pillar, 100+ supporting |
| Keyword difficulty | <40 new sites, <60 established |
| Search intent | Informational or commercial investigation |
| SERP features | Featured snippet opportunity = priority |

### 2. Content Brief

- Primary keyword + 3–5 secondary keywords
- Search intent, target word count from SERP analysis, competitor gaps
- Unique angle; internal link targets

### 3. Writing Pipeline

1. `content/story.md` — narrative framework
2. `content/research.md` — data and insights
3. `content/seo-writer.md` — keyword-optimized draft
4. `content/editor.md` — human voice transformation
5. `content/humanise.md` — remove AI patterns
6. `content/meta-creator.md` — title tag and meta description
7. `content/internal-linker.md` — strategic internal links

### 4. On-Page Optimization Checklist

- [ ] Primary keyword in title tag (first 60 chars), H1, first 100 words, meta description
- [ ] Secondary keywords in H2 headings
- [ ] Alt text on all images (include keyword where natural)
- [ ] 3–5 internal links; 2–3 external links to authoritative sources
- [ ] URL slug contains primary keyword
- [ ] Schema markup (Article, FAQ, HowTo as applicable)

### 5. Content Analysis

```bash
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze article.md --keyword "target keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md --keyword "keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md
```

## Content from Pipeline Assets

**From YouTube**: Extract transcript (`youtube-helper.sh transcript VIDEO_ID`) → restructure for reading → add SEO elements → expand with research → add visuals.

**From Research**: Use brief as foundation → structure around findings → add original analysis → include data (stats, charts) → link sources.

**From Short-Form**: Expand high-performing short → add depth (context, examples, methodology) → target related long-tail keywords → embed original video.

## Publishing Workflow

**WordPress**: Draft via WP REST API or WP-CLI; assign categories/tags; upload featured image; set Yoast/RankMath SEO fields; schedule. See `tools/wordpress/wp-dev.md`.

**Content Calendar**: Pillar 1–2/month · Supporting posts 2–4/week · Listicles 1–2/month · Refresh top performers quarterly.

**Post-Publish Checklist**:
- [ ] Verify indexing (Google Search Console)
- [ ] Share on social (`content/distribution-social.md`)
- [ ] Include in next newsletter (`content/distribution-email.md`)
- [ ] Internal link from 2–3 existing articles
- [ ] Monitor target keyword rankings weekly for first month

## Related

**Content pipeline**: `content/research.md` · `content/story.md` · `content/guidelines.md` · `content/optimization.md`

**SEO**: `seo.md` · `seo/keyword-research.md` · `seo/dataforseo.md` · `seo/google-search-console.md` · `seo/content-analyzer.md`

**Distribution**: `content/distribution-youtube.md` · `content/distribution-short-form.md` · `content/distribution-social.md` · `content/distribution-email.md` · `content/distribution-podcast.md`

**WordPress**: `tools/wordpress/wp-dev.md` · `tools/wordpress/mainwp.md`
