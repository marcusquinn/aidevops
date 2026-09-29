---
name: ecommerce-seo
description: >
  Ecommerce search architecture -- collections and categories, faceted navigation
  index policy, attribute/audience/"X for Y" drill-down, product titles and
  merchant feeds, Product/Offer schema, and long-tail to head-term authority flow.
  Use for Shopify, WooCommerce, marketplace and catalogue sites.
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Ecommerce SEO

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Registry**: targets, clusters and modifiers in `context/keywords/` (`seo/keywords-standard.md`). Heads = collections/categories; modifiers = attributes, audiences, use cases, compatibility, locations, price, brand, comparison.
- **Drill-down**: `aidevops keywords expand <head-id>` only for heads above `drilldown_min_priority`; candidates stay `candidate` until demand and inventory evidence promotes them.
- **Page policy per node** (`modifiers.page_policy`): `collection` → `facet-index` → `section`/`faq` → `attribute-only` → `none`.
- **Related**: `seo/programmatic-seo.md`, `seo/schema-validator.md`, `seo/image-seo.md`, `seo/site-crawler.md`, `seo/seo-audit-skill.md` (thin category/facet checks), `services/ecommerce/shopify.md` when `repos.json` `platform: shopify`.

<!-- AI-CONTEXT-END -->

## Architecture

- **Head terms own collections**: one collection or category URL per head phrase (`running shoes`), with intro copy that answers the head query and links to its strongest modifier pages.
- **Long tail feeds the head**: each drill-down page (`waterproof trail running shoes`, `running shoes for flat feet`) links up to its parent with head-term anchors and a BreadcrumbList. Sum of long-tail demand is the evidence for investing in the head.
- **"X for Y" searches** (audience, use case, problem, compatibility, occasion) often convert best; model them as `audience`/`use_case`/`problem`/`compatibility` modifiers with pattern `{head} for {value}`.
- **Comparisons and alternatives** (`{a} vs {b}`, `{brand} alternatives`) are separate `comparison` pages, not facets.

## Faceted navigation index policy

| Evidence | `page_policy` | Implementation |
|----------|---------------|----------------|
| Head demand, broad inventory | `collection` | Indexable, in sitemap, unique copy |
| Modifier demand >= `facet_min_demand` and >= `facet_min_items` products | `facet-index` | Static, crawlable URL (`/running-shoes/waterproof`), unique title/H1/intro, self-canonical |
| Some demand, thin inventory | `section` or `faq` | Answer on the parent page; no new URL |
| No demand, useful filter | `facet-noindex` | Parameter URL, `noindex,follow` or canonical to parent; blocked from sitemaps |
| Attribute only | `attribute-only` | Product data/filters only |

Combinations of two or more facets stay non-indexable unless they have their own demand and inventory evidence. Keep parameter order stable and avoid infinite crawl spaces.

## Products and feeds

- **Titles**: brand, product type (head phrase), key attributes from modifiers, then variant. Use the same order in page titles, Merchant Center/marketplace feeds, Product schema and image file names (`aidevops keywords brief --asset product`).
- **Descriptions**: unique per product; never copy manufacturer text across a catalogue. Answer the "for Y" use case in the first lines.
- **Schema**: Product + Offer (price, availability, currency), AggregateRating/Review only with real reviews, ItemList on collections, BreadcrumbList everywhere. Validate with `seo/schema-validator.md`.
- **Images**: variant-specific file names and alt text from the product title order; show the attribute that the modifier names.
- **Availability**: keep out-of-stock pages live with alternatives when demand persists; redirect permanently discontinued products to the closest collection.
- **Site search logs**: first-party demand evidence for new modifiers; import top unmatched queries as `candidate` targets.

## Verification

```bash
aidevops keywords validate          # one phrase per URL; intent mixing warnings
aidevops keywords report            # striking distance and movers per collection
site-crawler-helper.sh audit-meta https://example.com   # duplicate titles/descriptions on facets
```
