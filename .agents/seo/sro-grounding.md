---
name: sro-grounding
description: Optimize Selection Rate by improving grounding snippet eligibility, relevance density, and citation survivability
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# SRO Grounding

Selection Rate Optimization (SRO) focuses on whether a source gets selected into grounded context, not only whether it ranks.

## Quick Reference

- Purpose: improve source selection share in AI retrieval pipelines
- Core metric: Selection Rate (selected appearances / available retrieval opportunities)
- Inputs: query themes, ranked pages, extracted snippets, page structure and copy
- Outputs: snippet optimization recommendations, structural cleanup, SRO test plan

## Working Model

- AI retrieval often works with fixed context budgets
- Top-ranked and higher-relevance sources usually receive larger context share
- Long pages can suffer low content survival if key facts are buried
- Retrieval often includes domain-scoped probes (`site:brand.com ...`),
  so selection depends on whether internal page metadata matches likely
  category/feature modifiers

## SRO Workflow

### 1) Baseline snippet extraction behavior

- Collect snippets selected for representative intents
- Tag snippet type: lead paragraph, list item, heading-adjacent sentence, table row
- Identify what wins repeatedly and what never survives

### 2) Improve snippet fitness

- Rewrite critical statements as standalone, factual sentences
- Move essential facts closer to top-of-page sections
- Reduce dependency on surrounding context to interpret a sentence

### 3) Reduce structural noise

- Minimize repetitive boilerplate near top content blocks
- Keep heading hierarchy clean and predictable
- Avoid decorative text that competes with factual statements

### 4) Cover fan-out angles

- For each intent, map related sub-questions that retrieval systems may dispatch
- Ensure target page contains concise answers for each major angle
- Add internal links to deeper evidence where required

### 5) Validate with controlled re-tests

- Re-run the same intent set after updates
- Compare selected snippet quality, coverage breadth, and citation persistence
- Keep an SRO changelog tied to page revisions
- Re-test after index and model updates because grounding behavior is transient

## Content Rules for High Selection Likelihood

- Put key eligibility facts in opening sections
- Prefer short declarative sentences over vague promotional phrasing
- Keep numerics and qualifiers explicit (thresholds, limits, timelines)
- Use lists/tables only when they preserve factual precision
- Keep policy, pricing, and capability statements up-to-date
- Refresh critical sections on a defined cadence to preserve snippet freshness
- Include category terms in title, H1, and opening paragraph to match
  `site:` query shapes (for example: "[category] features", "[category] pricing")
- Keep meta descriptions specific and factual so retrieval systems can
  disambiguate similar pages during domain-scoped selection

## Optimizing for Domain-Scoped Retrieval

When an AI model runs a `site:yourdomain.com` query, it is searching your site specifically — not competing against the open web. The selection dynamics differ from open-web retrieval:

- **Page titles are query-match surfaces**: the model's `site:` query includes category terms and feature names. Page titles and H1s must contain these terms explicitly. A page titled "Our Platform" will not match `site:yourdomain.com enterprise ATS features` — but "Enterprise ATS Features & Capabilities" will.
- **Meta descriptions become retrieval previews**: in domain-scoped search, the meta description helps the model decide which of your pages to read. Write meta descriptions as factual summaries containing category terms, not marketing taglines.
- **Each page competes against your other pages, not competitors**: when the model searches your site, it picks the best-matching page from your domain. Ensure each major topic has a single authoritative page rather than spreading facts across multiple pages that partially match.
- **Heading hierarchy signals topic structure**: the model uses headings to locate specific sections within a page. Use descriptive headings that match likely query terms (`## Pricing Plans`, `## Enterprise Features`, `## Integration Partners`) rather than creative headings (`## Why We're Different`).
- **Standalone factual density matters more**: in domain-scoped retrieval, the model is extracting specific claims to compare against other brands. Every key fact should be a self-contained statement that makes sense without surrounding context.

## Common Failure Modes

- Important claims appear only deep in the page
- Contradictory facts across pages dilute confidence
- Overlong narrative sections bury actionable information
- Snippet candidates rely on pronouns and missing antecedents
- Page titles use brand-centric language instead of category terms that match `site:` query patterns
- Key product pages lack meta descriptions with factual summaries

## Related Subagents

- `geo-strategy.md` for criteria extraction and strategy
- `query-fanout-research.md` for thematic decomposition
- `ai-hallucination-defense.md` for consistency and evidence hygiene
