---
description: E-E-A-T content quality scoring and analysis
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

# E-E-A-T Score - Content Quality Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Audit E-E-A-T (Experience, Expertise, Authoritativeness, Trustworthiness) at scale
- **Helper**: `~/.aidevops/agents/scripts/eeat-score-helper.sh`
- **Input**: Site crawler data or URL list
- **Output**: `~/Downloads/{domain}/{datestamp}/` with `_latest` symlink
- **Formats**: CSV, XLSX with scores and reasoning

```bash
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json
eeat-score-helper.sh score https://example.com/article
eeat-score-helper.sh batch urls.txt
eeat-score-helper.sh report ~/Downloads/example.com/_latest/eeat-scores.json
```

**Scoring Criteria** (1-10 scale, weighted average):

| Criterion | Weight | Focus |
|-----------|--------|-------|
| Authorship & Expertise | 15% | Author credentials, verifiable entity |
| Citation Quality | 15% | Source quality, substantiation |
| Content Effort | 15% | Replicability, depth, original research |
| Original Content | 15% | Unique perspective, new information |
| Page Intent | 15% | Helpful-first vs search-first |
| Subjective Quality | 15% | Engagement, clarity, credibility |
| Writing Quality | 10% | Lexical diversity, readability |

<!-- AI-CONTEXT-END -->

## Pre-flight Questions

Before assessing or generating E-E-A-T content:

1. Are brand name, expert name, and credentials cited with verifiable sources?
2. Are there quality backlinks from authoritative domains supporting the claims?
3. Is NAP (name, address, phone) consistent across all mentions and structured data?
4. What is the entity density — are key entities mentioned with appropriate frequency?
5. Does this demonstrate first-hand experience, or just restate what already ranks?
6. Would a domain expert cite this — or dismiss it as surface-level?

## Scoring Guide

Based on [Ian Sorin's E-E-A-T audit guide](https://iansorin.fr/how-to-audit-e-e-a-t-at-scale/).

| Criterion | 1-3 | 4-6 | 7-10 |
|-----------|-----|-----|------|
| **Authorship** | No clear author, anonymous | Some attribution, weak credentials | Clear author, verifiable expertise, accountable |
| **Citation** | Bold claims, no citations | Some citations, mediocre quality | Core claims backed by primary sources |
| **Effort** | Generic, easily replicated | Some investment | Original research, proprietary data, unique tools |
| **Originality** | Templated, rehashed | Mix of original/generic | Substantively unique, new information |
| **Intent** | Search-first, deceptive | Mixed signals | Helpful-first, transparent purpose |
| **Subjective** | Boring, confusing, generic | Some good parts | Compelling, credible, dense value |
| **Writing** | Repetitive, passive, adverb-heavy | Some readability issues | Rich vocabulary, active voice, 15-20 word sentences |

**LLM prompt structure per criterion**: reasoning prompt (2-4 sentences) + scoring prompt (returns only a number 1-10).

## Usage

```bash
# Crawled pages
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json

# Single URL
eeat-score-helper.sh score https://example.com/blog/article --verbose

# Batch
eeat-score-helper.sh batch urls.txt

# Report
eeat-score-helper.sh report ~/Downloads/example.com/_latest/eeat-scores.json --output ~/Reports/
```

## Output

**Spreadsheet columns**: URL, Score/Reasoning per criterion, Overall Score (weighted avg), Grade

| Grade | Score | Interpretation |
|-------|-------|----------------|
| A | 8.0-10.0 | Excellent E-E-A-T |
| B | 6.5-7.9 | Good, minor improvements needed |
| C | 5.0-6.4 | Average, significant improvements needed |
| D | 3.5-4.9 | Poor, major issues |
| F | 1.0-3.4 | Very poor, likely harmful to SEO |

## Integration with Site Crawler

```bash
site-crawler-helper.sh crawl https://example.com --max-urls 100
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json
# Output: crawl-data.xlsx  example.com-eeat-score-{date}.xlsx  eeat-summary.json
```

## Configuration

`~/.config/aidevops/eeat-score.json`:

```json
{
  "llm_provider": "openai",
  "llm_model": "gpt-4o",
  "temperature": 0.3,
  "max_tokens": 500,
  "concurrent_requests": 3,
  "output_format": "xlsx",
  "include_reasoning": true,
  "weights": {
    "authorship": 0.15, "citation": 0.15, "effort": 0.15,
    "originality": 0.15, "intent": 0.15, "subjective": 0.15, "writing": 0.10
  }
}
```

```bash
export OPENAI_API_KEY="sk-..."   # or ANTHROPIC_API_KEY
export EEAT_OUTPUT_DIR="~/SEO-Audits"  # optional
```

## Common Fixes

| Low Score Area | Common Causes | Fix |
|----------------|---------------|-----|
| Authorship | No author bio, anonymous | Add detailed author bio with credentials |
| Citation | Unsupported claims | Add citations to primary sources |
| Effort | Generic content | Add original research, data, case studies |
| Originality | Rehashed content | Add unique perspective, proprietary insights |
| Intent | Keyword-stuffed | Focus on user value, remove SEO fluff |
| Subjective | Boring, unclear | Improve engagement, clarity, structure |
| Writing | Poor readability | Shorten sentences, vary vocabulary |

## Related Agents

- `seo/site-crawler.md` - Crawl sites for E-E-A-T analysis
- `content/guidelines.md` - Content creation best practices
- `tools/browser/crawl4ai.md` - Advanced content extraction
- `seo/google-search-console.md` - Search performance data
