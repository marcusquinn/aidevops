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

**Commands**:

```bash
# Analyze crawled pages
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json

# Analyze single URL
eeat-score-helper.sh score https://example.com/article

# Batch analyze URLs
eeat-score-helper.sh batch urls.txt

# Generate report from existing scores
eeat-score-helper.sh report ~/Downloads/example.com/_latest/eeat-scores.json
```text

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

## Overview

The E-E-A-T Score agent evaluates content quality using Google's E-E-A-T framework
(Experience, Expertise, Authoritativeness, Trustworthiness). It uses LLM-powered
analysis to score pages and provide actionable feedback.

Based on methodology from [Ian Sorin's E-E-A-T audit guide](https://iansorin.fr/how-to-audit-e-e-a-t-at-scale/).

## Scoring Criteria

### 1. Authorship & Expertise (isAuthor)

**What it measures**: Is there a clear, verifiable author with relevant expertise?

**Scoring Guide**:
- **1-3 (Disconnected Entity)**: No clear author, anonymous, untraceable, no way to find "who owns and operates"
- **4-6 (Partial)**: Some attribution but weak verifiability or unclear credentials
- **7-10 (Connected Entity)**: Clear author with detailed bio, verifiable expertise, accountable

**Key Questions**:
- Is there a clear author byline linking to a detailed biography?
- Does the About page clearly identify the company or person responsible?
- Is this entity verifiable and accountable?
- Do they demonstrate relevant expertise for this topic?

### 2. Citation Quality & Substantiation

**What it measures**: Are claims backed up with high-quality sources?

**Scoring Guide**:
- **1-3 (Low)**: Bold claims with no citations, or only low-quality/irrelevant links
- **4-6 (Moderate)**: Some citations but mediocre quality
- **7-10 (High)**: Core claims substantiated with primary sources or high-authority domains

**Key Questions**:
- Does the page make specific factual claims?
- Are those claims substantiated with citations/links?
- Quality of sources: Primary sources (studies, legal docs, official data)?
- Or are claims made with no support or low-quality sources?

### 3. Content Effort

**What it measures**: How much demonstrable effort, expertise, and resources were invested?

**Scoring Guide**:
- **1-3 (Low Effort)**: Generic, formulaic, easily replicated in hours
- **4-6 (Moderate)**: Some investment but not exceptional
- **7-8 (High Effort)**: Significant investment, hard to replicate, in-depth analysis
- **9-10 (Exceptional)**: Original research, proprietary data, unique tools

**Key Questions**:
- How difficult (time, cost, expertise) would it be for a competitor to replicate?
- Does the page "show its work"? (e.g., "I tested this," "I analyzed X data points")
- Evidence of original data, surveys, proprietary research?
- Unique multimedia, tools, interactive elements?

### 4. Original Content

**What it measures**: Does this content add new information to the web?

**Scoring Guide**:
- **1-3 (Low Originality)**: Templated, duplicated, just rehashes existing knowledge
- **4-6 (Moderate)**: Mix of original and generic elements
- **7-10 (High Originality)**: Substantively unique, adds new information or fresh perspective

**Red Flags**:
- Templated content
- Spun/paraphrased from other sources
- Generic information anyone could write

### 5. Page Intent

**What it measures**: Why was this page created? What is its primary purpose?

**Scoring Guide**:
- **1-3 (Deceptive/Search-First)**: Created primarily for search traffic, deceptive intent
- **4-6 (Unclear)**: Mixed signals
- **7-10 (Transparent/Helpful-First)**: Created primarily to help people, clear honest purpose

**Red Flags for Search-First**:
- Thin content designed just to rank for keywords
- Affiliate review disguised as unbiased analysis
- Content with no clear user value beyond SEO
- Keyword stuffing

**Green Flags for Helpful-First**:
- Clear user problem being solved
- Transparent about purpose (even if commercial)
- Genuine value for visitors

### 6. Subjective Quality

**What it measures**: Overall content quality from the reader's perspective.

**Scoring Guide**:
- **1-3 (Low Quality)**: Boring, confusing, unbelievable, generic advice, audience pain unclear
- **4-6 (Mediocre)**: Some good parts but significant issues with engagement, clarity, or value
- **7-10 (High Quality)**: Compelling, clear, credible, audience pain well-addressed, dense value

**Evaluation Dimensions**:
- **Engagement**: Is this content boring or compelling? Does it grab attention?
- **Clarity**: Is anything confusing? Are concepts explained well?
- **Credibility**: Do you believe the claims? Does it feel authentic?
- **Audience Targeting**: Is the target audience's pain point clearly addressed?
- **Value Density**: Is every section necessary? Are there proprietary insights?

### 7. Writing Quality

**What it measures**: Objective linguistic quality metrics.

**Scoring Guide**:
- **1-3 (Poor)**: Repetitive vocabulary, long complex sentences, excessive passive voice/adverbs
- **4-6 (Average)**: Some issues with readability, vocabulary, or linguistic quality
- **7-10 (Excellent)**: Rich vocabulary, optimal sentence length, active voice, concise writing

**Metrics Evaluated**:
- **Lexical Diversity**: Vocabulary richness, varied word choice
- **Readability**: Sentence length (15-20 words optimal), mix of easy/medium sentences
- **Modal Verbs**: Balanced use (not too rigid, not too uncertain)
- **Passive Voice**: Minimal use (passive dilutes action and clarity)
- **Heavy Adverbs**: Limited use of "absolutely," "clearly," "always," etc.

## Analysis Prompts

The following prompts are used for LLM-based analysis. Each criterion has both a
reasoning prompt (for explanation) and a scoring prompt (for numeric score).

### Subjective Quality Reasoning

```text
You are a brutally honest content critic. Be direct, not nice. Evaluate this content for:
boring sections, confusing parts, unbelievable claims, unclear audience pain point,
missing culprit identification, sections that could be condensed, and lack of proprietary
insights.

CRITICAL OUTPUT REQUIREMENT: Provide EXACTLY 2-3 sentences summarizing the main weaknesses.
NO bullet points. NO lists. NO section headers. NO more than 3 sentences.

Format example (good output): "This reads like generic advice with no data to back bold
claims about X and Y, making it unconvincing. The target audience pain isn't quantified
(no revenue/traffic loss cited), and there's zero proprietary data (screenshots, case
studies, exact prompts) to make it unique or credible."

Now analyze the content and provide your 2-3 sentence critique focused on what's broken
and needs fixing.
```text

### Authorship & Expertise Reasoning

```text
You are evaluating Authorship & Expertise for this page. Analyze and explain in 3-4 sentences:
- Is there a clear AUTHOR? If yes, who and what credentials?
- Can you identify the PUBLISHER (who owns/operates the site)?
- Is this a "Disconnected Entity" (anonymous, untraceable) or "Connected Entity" (verifiable)?
- Do they demonstrate RELEVANT EXPERTISE for this topic?

Be specific with names, credentials, evidence from the page.
```text

### Authorship & Expertise Score

```text
You are evaluating Authorship & Expertise (isAuthor criterion).

CRITICAL: A "Disconnected Entity" is one where you CANNOT find "who owns and operates"
the site. The entity is anonymous and untraceable.

Evaluate:
- Is there a clear author byline linking to a detailed biography?
- Does the About page clearly identify the company or person responsible?
- Is this entity VERIFIABLE and ACCOUNTABLE?
- Do they demonstrate RELEVANT EXPERTISE for this topic?

Score 1-10:
1-3 = DISCONNECTED ENTITY: No clear author, anonymous, untraceable
4-6 = Partial attribution, but weak verifiability or unclear credentials
7-10 = CONNECTED ENTITY: Clear author with detailed bio, verifiable expertise

Return ONLY the number (e.g., "3")
```text

### Citation Quality Reasoning

```text
You are evaluating Citation Quality for this page. Analyze and explain in 3-4 sentences:
- Does the page make SPECIFIC FACTUAL CLAIMS?
- Are those claims SUBSTANTIATED with citations?
- QUALITY assessment: Primary sources (studies, official docs) or secondary/low-quality?
- Or are claims unsupported?

Be specific with examples of claims and their (lack of) citations.
```text

### Citation Quality Score

```text
You are evaluating Citation Quality & Substantiation.

Does this content BACK UP its claims with high-quality sources?

Analyze:
- Does the page make SPECIFIC FACTUAL CLAIMS?
- Are those claims SUBSTANTIATED with citations/links?
- QUALITY of sources: Primary sources (studies, legal docs, official data)?
- Or are claims made with NO SUPPORT or low-quality sources?

Score 1-10:
1-3 = LOW: Bold claims with NO citations, or only low-quality/irrelevant links
4-6 = MODERATE: Some citations but mediocre quality
7-10 = HIGH: Core claims substantiated with primary sources or high-authority domains

Return ONLY the number (e.g., "7")
```text

### Content Effort Reasoning

```text
You are evaluating Content Effort for this page. Analyze and explain in 3-4 sentences:
- How DIFFICULT would it be to REPLICATE this content? (consider time, cost, expertise)
- Does the page "SHOW ITS WORK"? Is the creation process transparent?
- What evidence of high/low effort? (original research, data, multimedia, depth)
- Any unique elements that required significant resources?

Be specific with examples from the page.
```text

### Content Effort Score

```text
You are evaluating Content Effort.

Assess the DEMONSTRABLE effort, expertise, and resources invested in creating this content.

Key questions:
1. REPLICABILITY: How difficult (time, cost, expertise) would it be for a competitor
   to create content of equal or better quality?
2. CREATION PROCESS: Does the page "show its work"? (e.g., "I tested this,"
   "I analyzed X data points," "I interviewed Y experts")

Look for:
- In-depth analysis and research
- Original data, surveys, proprietary research
- Unique multimedia, tools, interactive elements
- Transparent methodology

Score 1-10:
1-3 = LOW EFFORT: Generic, formulaic, easily replicated in hours
7-8 = HIGH EFFORT: Significant investment, hard to replicate, in-depth analysis
9-10 = EXCEPTIONAL: Original research, proprietary data, unique tools

Return ONLY the number (e.g., "5")
```text

### Original Content Reasoning

```text
You are evaluating Content Originality for this page. Analyze and explain in 3-4 sentences:
- Does this page introduce NEW INFORMATION or a UNIQUE PERSPECTIVE?
- Or does it just REPHRASE existing knowledge from other sources?
- Is it substantively unique in phrasing, data, angle, or presentation?
- What makes it original or generic?

Be specific with examples.
```text

### Original Content Score

```text
You are evaluating Content Originality.

Does this content ADD NEW INFORMATION to the web, or just rephrase what already exists?

Evaluate:
- Is the content SUBSTANTIVELY UNIQUE in its phrasing, perspective, data, or presentation?
- Does it introduce NEW INFORMATION or a UNIQUE ANGLE?
- Or does it merely SUMMARIZE/REPHRASE what others have already said?

Red flags:
- Templated content
- Spun/paraphrased from other sources
- Generic information anyone could write

Score 1-10:
1-3 = LOW ORIGINALITY: Templated, duplicated, just rehashes existing knowledge
4-6 = MODERATE: Mix of original and generic elements
7-10 = HIGH ORIGINALITY: Substantively unique, adds new information or fresh perspective

Return ONLY the number (e.g., "6")
```text

### Page Intent Reasoning

```text
You are evaluating Page Intent for this page. Analyze and explain in 3-4 sentences:
- What is this page's PRIMARY PURPOSE (the "WHY" it exists)?
- Is it HELPFUL-FIRST (created to help users) or SEARCH-FIRST (created to rank)?
- Is the intent TRANSPARENT and honest, or DECEPTIVE?
- What evidence supports your assessment?

Be specific with examples from the content.
```text

### Page Intent Score

```text
You are evaluating Page Intent.

WHY was this page created? What is its PRIMARY PURPOSE?

Determine if this is:
- HELPFUL-FIRST: Created primarily to help users/answer questions/solve problems
- Or SEARCH-FIRST: Created primarily to rank in search and attract traffic

Red flags for "search-first":
- Thin content designed just to rank for keywords
- Affiliate review disguised as unbiased analysis
- Content with no clear user value beyond SEO
- Keyword stuffing

Green flags for "helpful-first":
- Clear user problem being solved
- Transparent about purpose (even if commercial)
- Genuine value for visitors

Score 1-10:
1-3 = DECEPTIVE/SEARCH-FIRST: Created primarily for search traffic, deceptive intent
4-6 = UNCLEAR: Mixed signals
7-10 = TRANSPARENT/HELPFUL-FIRST: Created primarily to help people, clear honest purpose

Return ONLY the number (e.g., "9")
```text

### Subjective Quality Score

```text
You are a brutally honest content critic evaluating subjective quality from the
reader's perspective.

CRITICAL: Put on your most critical hat. Don't be nice. High standards only.

Evaluate this content across these dimensions:

ENGAGEMENT:
- Is this content boring or compelling?
- Does it grab and maintain attention?
- Would the target audience actually want to read this?

CLARITY:
- Is anything confusing or unclear?
- Are concepts explained well?
- Is the structure logical?

CREDIBILITY:
- Do you believe the claims?
- Does it feel authentic or generic?
- Any BS detector going off?

AUDIENCE TARGETING:
- Is the target audience's PAIN POINT clearly identified and addressed?
- Is the "culprit" causing that pain point identified?
- Does this genuinely help the reader or just exist?

VALUE DENSITY:
- Is every section necessary or is there fluff?
- Could sections be condensed without losing value?
- Are there proprietary insights or just generic advice?

Score 1-10:
1-3 = LOW QUALITY: Boring, confusing, unbelievable, generic advice
4-6 = MEDIOCRE: Some good parts but significant issues
7-10 = HIGH QUALITY: Compelling, clear, credible, dense value

Return ONLY the number (e.g., "5")
```text

### Writing Quality Reasoning

```text
You are a writing quality analyst. Evaluate this text's linguistic quality.

Analyze: lexical diversity (vocabulary richness/repetition), readability
(sentence length 15-20 words optimal, simple vs complex sentences), modal verbs
balance, passive voice usage, and heavy adverbs.

CRITICAL OUTPUT REQUIREMENT: Provide EXACTLY 2-3 sentences summarizing the main
writing issues and what to improve. NO bullet points. NO lists. NO section headers.
Maximum 150 words total.

Format example (good output): "Vocabulary is repetitive with key terms overused
throughout, reducing readability. Sentences average too long (25+ words) with
excessive passive voice weakening directness; switch to active voice and shorten
sentences to 15-20 words. Cut heavy adverbs like 'absolutely' and 'clearly' to
tighten prose."

Now provide your compact 2-3 sentence critique focused on the main writing weaknesses.
```text

### Writing Quality Score

```text
You are a writing quality analyst evaluating text based on objective linguistic metrics.

Analyze this content across these dimensions:

1. LEXICAL DIVERSITY (vocabulary richness):
   - Rich vocabulary with varied word choice?
   - Or repetitive with limited vocabulary?

2. READABILITY (sentence structure):
   - Sentence length: 15-20 words per sentence optimal
   - Mix of easy/medium sentences, avoiding difficult ones
   - Syllables per word: 1.5-2.5 optimal

3. LINGUISTIC QUALITY:
   - MODAL VERBS (can, should, must, may): Balanced use
   - PASSIVE VOICE: Minimal use (passive dilutes action)
   - HEAVY ADVERBS (absolutely, clearly, always): Limited use

Score 1-10:
1-3 = POOR: Repetitive vocabulary, long complex sentences, excessive passive/adverbs
4-6 = AVERAGE: Some issues with readability, vocabulary, or linguistic quality
7-10 = EXCELLENT: Rich vocabulary, optimal sentence length, active voice, concise

Return ONLY the number (e.g., "6")
```text

## Usage

### Analyze Crawled Pages

After running a site crawl with `site-crawler-helper.sh`:

```bash
# Analyze all crawled pages
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json

# Output: ~/Downloads/example.com/{datestamp}/
#   - example.com-eeat-score-{datestamp}.xlsx
#   - example.com-eeat-score-{datestamp}.csv
#   - eeat-summary.json
```text

### Analyze Single URL

```bash
# Quick single-page analysis
eeat-score-helper.sh score https://example.com/blog/article

# With verbose reasoning output
eeat-score-helper.sh score https://example.com/blog/article --verbose
```text

### Batch Analysis

```bash
# Create URL list
cat > urls.txt << EOF
https://example.com/blog/post-1
https://example.com/blog/post-2
https://example.com/blog/post-3
EOF

# Analyze all URLs
eeat-score-helper.sh batch urls.txt
```text

### Generate Report

```bash
# Generate spreadsheet from existing scores
eeat-score-helper.sh report ~/Downloads/example.com/_latest/eeat-scores.json

# Custom output location
eeat-score-helper.sh report scores.json --output ~/Reports/
```text

## Output Format

### Spreadsheet Columns

| Column | Description |
|--------|-------------|
| URL | Page URL |
| Authorship Score | 1-10 score |
| Authorship Reasoning | Explanation |
| Citation Score | 1-10 score |
| Citation Reasoning | Explanation |
| Content Effort Score | 1-10 score |
| Content Effort Reasoning | Explanation |
| Original Content Score | 1-10 score |
| Original Content Reasoning | Explanation |
| Page Intent Score | 1-10 score |
| Page Intent Reasoning | Explanation |
| Subjective Quality Score | 1-10 score |
| Subjective Quality Reasoning | Explanation |
| Writing Quality Score | 1-10 score |
| Writing Quality Reasoning | Explanation |
| **Overall Score** | Weighted average |
| **Grade** | A/B/C/D/F based on overall |

### Grading Scale

| Grade | Score Range | Interpretation |
|-------|-------------|----------------|
| A | 8.0-10.0 | Excellent E-E-A-T, high-quality content |
| B | 6.5-7.9 | Good E-E-A-T, minor improvements needed |
| C | 5.0-6.4 | Average E-E-A-T, significant improvements needed |
| D | 3.5-4.9 | Poor E-E-A-T, major issues |
| F | 1.0-3.4 | Very poor E-E-A-T, content likely harmful to SEO |

## Integration with Site Crawler

The E-E-A-T Score agent works seamlessly with the Site Crawler:

```bash
# 1. Crawl the site
site-crawler-helper.sh crawl https://example.com --max-urls 100

# 2. Analyze E-E-A-T for crawled pages
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json

# 3. Results in same domain folder with _latest symlink
ls ~/Downloads/example.com/_latest/
# crawl-data.xlsx
# example.com-eeat-score-2025-01-15.xlsx
# eeat-summary.json
```text

## Configuration

### LLM Provider

Set your preferred LLM provider in `~/.config/aidevops/eeat-score.json`:

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
    "authorship": 0.15,
    "citation": 0.15,
    "effort": 0.15,
    "originality": 0.15,
    "intent": 0.15,
    "subjective": 0.15,
    "writing": 0.10
  }
}
```text

### Environment Variables

```bash
# Required: LLM API key
export OPENAI_API_KEY="sk-..."
# or
export ANTHROPIC_API_KEY="..."

# Optional: Custom output directory
export EEAT_OUTPUT_DIR="~/SEO-Audits"
```text

## Interpreting Results

### What Good Scores Mean

**High Authorship (8+)**: Clear author with verifiable credentials, transparent about who operates the site.

**High Citation (8+)**: Claims backed by primary sources, studies, official documentation.

**High Effort (8+)**: Original research, proprietary data, significant time investment evident.

**High Originality (8+)**: Unique perspective, new information not found elsewhere.

**High Intent (8+)**: Clearly helpful to users, transparent purpose, genuine value.

**High Subjective (8+)**: Engaging, clear, credible, addresses audience pain points.

**High Writing (8+)**: Rich vocabulary, optimal sentence length, active voice.

### Common Issues & Fixes

| Low Score Area | Common Causes | Fixes |
|----------------|---------------|-------|
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
