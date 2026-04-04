---
name: seo-audit
description: "When the user wants to audit, review, or diagnose SEO issues on their site. Also use when the user mentions \"SEO audit,\" \"technical SEO,\" \"why am I not ranking,\" \"SEO issues,\" \"on-page SEO,\" \"meta tags review,\" or \"SEO health check.\" For building pages at scale to target keywords, see programmatic-seo. For adding structured data, see schema-markup."
mode: subagent
imported_from: external
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SEO Audit

**Before auditing:** Read `.claude/product-marketing-context.md` if it exists. Clarify: site type (SaaS, e-commerce, blog), primary goal, priority keywords, known issues, traffic baseline, recent changes/migrations, scope (full site vs. specific pages), Search Console access.

## Audit Priority Order

1. **Crawlability & Indexation** — can Google find and index it?
2. **Technical Foundations** — fast and functional?
3. **On-Page Optimization** — content optimized?
4. **Content Quality** — deserves to rank?
5. **Authority & Links** — credible?

## Technical SEO Audit

### Crawlability

**Robots.txt:** No unintentional blocks; important pages allowed; sitemap referenced.

**XML Sitemap:** Exists, accessible, submitted to Search Console; canonical indexable URLs only; updated regularly.

**Site Architecture:** Important pages ≤3 clicks from homepage; logical hierarchy; no orphan pages; internal linking intact.

**Crawl Budget** (large sites): Parameterized URLs controlled; faceted nav handled; no session IDs in URLs; infinite scroll has pagination fallback.

### Indexation

**Index Status:** Run `site:domain.com`; check Search Console coverage; compare indexed vs. expected count.

**Indexation Issues:** Noindex on important pages; canonicals pointing wrong; redirect chains/loops; soft 404s; duplicate content without canonicals.

**Canonicalization:** All pages have canonical tags; self-referencing on unique pages; HTTP→HTTPS; www/non-www consistent; trailing slash consistent.

### Site Speed & Core Web Vitals

| Metric | Target |
|--------|--------|
| LCP (Largest Contentful Paint) | < 2.5s |
| INP (Interaction to Next Paint) | < 200ms |
| CLS (Cumulative Layout Shift) | < 0.1 |

Speed factors: TTFB, image optimization, JS/CSS delivery, caching, CDN, font loading.

Tools: PageSpeed Insights (`tools/browser/pagespeed.md`), Search Console Core Web Vitals report.

### Mobile, Security & URLs

**Mobile:** Responsive; viewport configured; tap targets sized; same content as desktop (mobile-first indexing).

**HTTPS:** Valid SSL; no mixed content; HTTP→HTTPS redirects; HSTS header (bonus).

**URLs:** Readable; keywords where natural; lowercase, hyphen-separated; no unnecessary parameters; consistent structure.

## On-Page SEO Audit

### Title Tags

- Unique; primary keyword near start; 50–60 chars; compelling; brand at end
- Issues: duplicates, truncation, keyword stuffing, missing

### Meta Descriptions

- Unique; 150–160 chars; primary keyword; clear value prop with CTA
- Issues: duplicates, auto-generated, no reason to click

### Heading Structure

- One H1 with primary keyword; logical hierarchy (H1→H2→H3); headings describe content
- Issues: multiple H1s, skipped levels, decorative-only headings

### Content Optimization

- Keyword in first 100 words; related keywords natural; sufficient depth; satisfies search intent; better than competitors
- Thin content: tag/category pages with no value, doorway pages, near-duplicates

### Image Optimization

- Descriptive file names; alt text on all images; compressed; WebP; lazy loading; responsive

### Internal Linking

- Important pages well-linked with descriptive anchors; no broken links; no orphans; avoid excessive footer/sidebar links; no over-optimized anchors

### Keyword Targeting

- Per page: clear primary target; title, H1, URL aligned; satisfies intent; no cannibalization
- Site-wide: keyword mapping; no gaps; logical topical clusters

## Content Quality Assessment

### E-E-A-T Signals

| Dimension | Signals |
|-----------|---------|
| **Experience** | First-hand experience; original insights/data; real examples |
| **Expertise** | Author credentials visible; accurate, detailed, sourced content |
| **Authoritativeness** | Recognized in space; cited by others; industry credentials |
| **Trustworthiness** | Accurate info; transparent business; contact info; privacy policy; HTTPS |

### Content Depth & Engagement

- Comprehensive coverage; answers follow-up questions; better than top competitors; current
- Monitor: time on page, bounce rate in context, pages per session, return visits

## Common Issues by Site Type

| Site Type | Common Issues |
|-----------|--------------|
| **SaaS/Product** | Thin product/feature pages; blog not integrated; missing comparison pages; no glossary |
| **E-commerce** | Thin category pages; duplicate product descriptions; missing product schema; faceted nav duplicates; out-of-stock mishandled |
| **Content/Blog** | Outdated content; keyword cannibalization; no topical clustering; poor internal linking; missing author pages |
| **Local Business** | Inconsistent NAP; missing local schema; no Google Business Profile; missing location pages |

## Output Format

**Executive Summary:** Overall health; top 3–5 priority issues; quick wins.

**Findings** (Technical SEO / On-Page / Content — same format):

| Field | Content |
|-------|---------|
| Issue | What's wrong |
| Impact | High / Medium / Low |
| Evidence | How you found it |
| Fix | Specific recommendation |
| Priority | 1–5 or High/Medium/Low |

**Prioritized Action Plan:**
1. Critical fixes (blocking indexation/ranking)
2. High-impact improvements
3. Quick wins (easy, immediate benefit)
4. Long-term recommendations

## References

- [AI Writing Detection](seo-audit-skill/ai-writing-detection.md): Common AI writing patterns to avoid (em dashes, overused phrases, filler words)
- [AEO & GEO Patterns](seo-audit-skill/aeo-geo-patterns.md): Content patterns optimized for answer engines and AI citation

## Tools

**Free:** Google Search Console (essential), PageSpeed Insights, Bing Webmaster Tools, Rich Results Test, Mobile-Friendly Test, [Schema Validator](schema-validator.md) (`schema-validator-helper.sh validate <url>`)

**Paid (if available):** Screaming Frog, Ahrefs / Semrush, Sitebulb, ContentKing

## Clarifying Questions

1. What pages/keywords matter most?
2. Search Console access?
3. Recent changes or migrations?
4. Top organic competitors?
5. Current organic traffic baseline?

## Related Skills

- **programmatic-seo**: For building SEO pages at scale
- **schema-markup**: For implementing structured data
- **schema-validator**: For validating Schema.org structured data (JSON-LD, Microdata, RDFa)
- **[mom-test-ux](mom-test-ux.md)**: For UX evaluation and CRO
- **analytics-tracking**: For measuring SEO performance
