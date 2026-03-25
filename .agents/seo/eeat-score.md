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

**Scoring Criteria** (1-10 scale):

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

Before assessing or generating E-E-A-T content, work through:

1. Are brand name, expert name, and credentials cited with verifiable sources?
2. Are there quality backlinks from authoritative domains supporting the claims?
3. Is NAP (name, address, phone) consistent across all mentions and structured data?
4. What is the entity density — are key entities mentioned with appropriate frequency and semantic weight?
5. Does this demonstrate first-hand experience, or just restate what already ranks?
6. Would a domain expert cite this — or dismiss it as surface-level?

## Overview

The E-E-A-T Score agent evaluates content quality using Google's E-E-A-T framework. It uses LLM-powered analysis to score pages and provide actionable feedback.

Based on methodology from [Ian Sorin's E-E-A-T audit guide](https://iansorin.fr/how-to-audit-e-e-a-t-at-scale/).

## Scoring Criteria

### 1. Authorship & Expertise (isAuthor)

**Scoring Guide**:
- **1-3 (Disconnected Entity)**: No clear author, anonymous, untraceable
- **4-6 (Partial)**: Some attribution but weak verifiability or unclear credentials
- **7-10 (Connected Entity)**: Clear author with detailed bio, verifiable expertise, accountable

**Key Questions**: Clear author byline with bio? About page identifies responsible entity? Verifiable and accountable? Relevant expertise for the topic?

### 2. Citation Quality & Substantiation

**Scoring Guide**:
- **1-3 (Low)**: Bold claims with no citations, or only low-quality/irrelevant links
- **4-6 (Moderate)**: Some citations but mediocre quality
- **7-10 (High)**: Core claims substantiated with primary sources or high-authority domains

**Key Questions**: Specific factual claims made? Claims substantiated with citations? Primary sources (studies, legal docs, official data) or secondary/low-quality?

### 3. Content Effort

**Scoring Guide**:
- **1-3 (Low Effort)**: Generic, formulaic, easily replicated in hours
- **4-6 (Moderate)**: Some investment but not exceptional
- **7-8 (High Effort)**: Significant investment, hard to replicate, in-depth analysis
- **9-10 (Exceptional)**: Original research, proprietary data, unique tools

**Key Questions**: How difficult to replicate (time, cost, expertise)? Does it "show its work"? Evidence of original data, surveys, proprietary research? Unique multimedia or interactive elements?

### 4. Original Content

**Scoring Guide**:
- **1-3 (Low Originality)**: Templated, duplicated, just rehashes existing knowledge
- **4-6 (Moderate)**: Mix of original and generic elements
- **7-10 (High Originality)**: Substantively unique, adds new information or fresh perspective

**Red Flags**: Templated content, spun/paraphrased from other sources, generic information anyone could write.

### 5. Page Intent

**Scoring Guide**:
- **1-3 (Deceptive/Search-First)**: Created primarily for search traffic, deceptive intent
- **4-6 (Unclear)**: Mixed signals
- **7-10 (Transparent/Helpful-First)**: Created primarily to help people, clear honest purpose

**Red Flags**: Thin content for keywords, affiliate review disguised as unbiased, keyword stuffing. **Green Flags**: Clear user problem solved, transparent purpose, genuine value.

### 6. Subjective Quality

**Scoring Guide**:
- **1-3 (Low Quality)**: Boring, confusing, unbelievable, generic advice, audience pain unclear
- **4-6 (Mediocre)**: Some good parts but significant issues
- **7-10 (High Quality)**: Compelling, clear, credible, audience pain well-addressed, dense value

**Dimensions**: Engagement, Clarity, Credibility, Audience Targeting (pain point identified?), Value Density (proprietary insights vs fluff).

### 7. Writing Quality

**Scoring Guide**:
- **1-3 (Poor)**: Repetitive vocabulary, long complex sentences, excessive passive voice/adverbs
- **4-6 (Average)**: Some issues with readability, vocabulary, or linguistic quality
- **7-10 (Excellent)**: Rich vocabulary, optimal sentence length, active voice, concise writing

**Metrics**: Lexical diversity, sentence length (15-20 words optimal), modal verb balance, passive voice (minimize), heavy adverbs (minimize: "absolutely," "clearly," "always").

## Analysis Prompts

The helper script uses LLM prompts for each criterion. Each criterion has a **reasoning prompt** (2-4 sentence explanation) and a **scoring prompt** (returns only a number 1-10).

**Prompt structure for each criterion**:

- **Authorship**: Identify author, publisher, connected vs disconnected entity, relevant expertise
- **Citation**: Specific factual claims present? Substantiated with primary sources or unsupported?
- **Content Effort**: Replicability difficulty, "shows its work," original data/research/multimedia
- **Original Content**: New information vs rephrase? Unique angle, perspective, or data?
- **Page Intent**: Helpful-first vs search-first? Transparent purpose or deceptive?
- **Subjective Quality**: Brutally honest critique — engagement, clarity, credibility, audience pain, value density
- **Writing Quality**: Lexical diversity, sentence length, modal verbs, passive voice, heavy adverbs

All scoring prompts return **only a number** (e.g., `"7"`). Reasoning prompts return 2-4 sentences with no bullet points or headers.

## Usage

### Analyze Crawled Pages

```bash
# After running site-crawler-helper.sh
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json
# Output: ~/Downloads/example.com/{datestamp}/
#   - example.com-eeat-score-{datestamp}.xlsx
#   - example.com-eeat-score-{datestamp}.csv
#   - eeat-summary.json
```

### Analyze Single URL

```bash
eeat-score-helper.sh score https://example.com/blog/article
eeat-score-helper.sh score https://example.com/blog/article --verbose
```

### Batch Analysis

```bash
cat > urls.txt << EOF
https://example.com/blog/post-1
https://example.com/blog/post-2
EOF
eeat-score-helper.sh batch urls.txt
```

### Generate Report

```bash
eeat-score-helper.sh report ~/Downloads/example.com/_latest/eeat-scores.json
eeat-score-helper.sh report scores.json --output ~/Reports/
```

## Output Format

### Spreadsheet Columns

URL, Authorship Score/Reasoning, Citation Score/Reasoning, Content Effort Score/Reasoning, Original Content Score/Reasoning, Page Intent Score/Reasoning, Subjective Quality Score/Reasoning, Writing Quality Score/Reasoning, **Overall Score** (weighted average), **Grade**

### Grading Scale

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
ls ~/Downloads/example.com/_latest/
# crawl-data.xlsx  example.com-eeat-score-2025-01-15.xlsx  eeat-summary.json
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

## Interpreting Results & Common Fixes

| Low Score Area | Common Causes | Fixes |
|----------------|---------------|-------|
| Authorship | No author bio, anonymous | Add detailed author bio with credentials |
| Citation | Unsupported claims | Add citations to primary sources |
| Effort | Generic content | Add original research, data, case studies |
| Originality | Rehashed content | Add unique perspective, proprietary insights |
| Intent | Keyword-stuffed | Focus on user value, remove SEO fluff |
| Subjective | Boring, unclear | Improve engagement, clarity, structure |
| Writing | Poor readability | Shorten sentences, vary vocabulary |

**High scores (8+) mean**: Clear verifiable author, claims backed by primary sources, original research evident, unique perspective, clearly helpful to users, engaging and credible, rich vocabulary with active voice.

## Related Agents

- `seo/site-crawler.md` - Crawl sites for E-E-A-T analysis
- `content/guidelines.md` - Content creation best practices
- `tools/browser/crawl4ai.md` - Advanced content extraction
- `seo/google-search-console.md` - Search performance data
