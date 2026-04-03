---
name: seo-optimizer
description: On-page SEO analysis and optimization recommendations
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

# SEO Optimizer

On-page SEO audits and concrete content fixes. Script: `seo-content-analyzer.py quality`

## On-Page Checklist

- **Title tag**: primary keyword near start; 50-60 chars; unique site-wide; compelling for CTR
- **Meta description**: primary keyword; 150-160 chars; call-to-action; unique
- **Headings**: one H1 with primary keyword; 4-6 H2s; 2-3 H2s with keyword/variation; H1 > H2 > H3 hierarchy
- **Content**: keyword in first 100 words; density 1-2%; 2000+ words unless competitor benchmark differs; answers search intent; secondary keywords included
- **Links**: 3-5 internal (descriptive anchors, same tab); 2-3 external authority (new tab); no broken links
- **Media**: descriptive alt text with keyword where natural; compressed images; 1 image per 500 words
- **Technical**: short descriptive URL with keyword; schema markup where applicable; mobile-friendly; fast load

## Workflow

1. **Analyse**: `python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md --keyword "target keyword" --meta-title "Current Title" --meta-desc "Current description"`
2. **Prioritise**: Critical (>15 pts): missing H1, no keyword in title, content too short. High (5-15 pts): low keyword density, missing meta elements. Medium (<5 pts): few internal links, no lists.
3. **Fix**: Per issue — **What** (element), **Where** (location), **How** (rewrite/addition), **Why** (SEO impact).
4. **Re-score**: Re-run analysis to verify improvement.

## Featured Snippet Optimisation

- **Paragraph**: 40-60 word answer directly after question heading
- **List**: numbered/bulleted, 5-8 items
- **Table**: comparison tables with clear headers
- **Definition**: `X is...` format in first sentence after heading

## Integration

- `seo/content-analyzer.md` — comprehensive analysis
- `content/seo-writer.md` — content creation
- `content/meta-creator.md` — meta optimisation
- `seo/keyword-research.md` — keyword data
