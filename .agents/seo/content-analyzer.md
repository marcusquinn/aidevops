---
name: content-analyzer
description: Comprehensive SEO content analysis - readability, keyword density, search intent, quality scoring
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

# SEO Content Analyzer

Full content audit via `seo-content-analyzer.py` — 5 Python modules covering readability, keyword density, search intent, content length, and SEO quality scoring.

## Quick Reference

- **Input**: Article file/URL, primary keyword, secondary keywords
- **Output**: Executive summary with scores, publishing readiness, priority actions
- **Script**: `~/.aidevops/agents/scripts/seo-content-analyzer.py`

## Analysis Pipeline

```bash
# Full analysis (readability + keywords + quality + intent)
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze article.md \
  --keyword "primary keyword" \
  --secondary "secondary1,secondary2"

# Individual analyses
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md \
  --keyword "primary keyword" --secondary "secondary1,secondary2"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py intent "target keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md \
  --keyword "primary keyword" \
  --meta-title "Article Title Here" --meta-desc "Article description here"
```

## Analysis Categories

| Module | Key Metrics |
|--------|-------------|
| **Readability** | Flesch Reading Ease (target: 60-70), Flesch-Kincaid Grade (target: 8-10), sentence length, passive voice ratio, transition words, complex word ratio |
| **Keyword Optimization** | Primary density (target: 1-2%), critical placements (H1/first 100 words/H2s/conclusion), section heatmap, stuffing risk, LSI suggestions, secondary coverage |
| **Search Intent** | Intent classification (informational/navigational/transactional/commercial), confidence scores, content-intent alignment, SERP feature targeting |
| **SEO Quality** | 6-category scoring (content, keywords, meta, structure, links, readability), critical issues, publishing readiness, meta element validation |

Output report structure: scores table → Publishing Readiness (Yes/No) → Priority Actions (Critical / High Priority / Optimization) → Detailed Findings per module.

## Integration

- Feeds into `content/seo-writer.md` for content creation
- Uses data from `seo/dataforseo.md` for SERP competitor data
- Works with `seo/eeat-score.md` for quality validation
- Results inform `content/meta-creator.md` for meta optimisation
