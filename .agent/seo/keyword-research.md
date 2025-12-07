# Keyword Research

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Comprehensive keyword research with SERP weakness detection and opportunity scoring
- **Providers**: DataForSEO (primary), Serper (alternative), Ahrefs (optional DR/UR)
- **Commands**: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`
- **Config**: `~/.config/aidevops/keyword-research.json`

**Research Modes**:

| Mode | Flag | Purpose |
|------|------|---------|
| Keyword Research | (default) | Expand seed keywords with related suggestions |
| Autocomplete | `/autocomplete-research` | Google autocomplete long-tail expansion |
| Domain Research | `--domain` | Keywords associated with a domain's niche |
| Competitor Research | `--competitor` | Exact keywords a competitor ranks for |
| Keyword Gap | `--gap` | Keywords competitor ranks for that you don't |

**Analysis Levels**:

| Level | Flag | Data Returned |
|-------|------|---------------|
| Quick | `--quick` | Volume, CPC, KD, Intent |
| Full | `--full` (default for extended) | + KeywordScore, Domain Score, 17 weaknesses |

<!-- AI-CONTEXT-END -->

## Commands

### /keyword-research

Basic keyword expansion from seed keywords.

```bash
/keyword-research "best seo tools, keyword research"
```

**Output**: Volume, CPC, Keyword Difficulty, Search Intent

**Options**:
- `--limit N` - Number of results (default: 100, max: 10,000)
- `--provider dataforseo|serper|both` - Data source
- `--csv` - Export to ~/Downloads/
- `--min-volume N` - Minimum search volume
- `--max-difficulty N` - Maximum keyword difficulty
- `--intent informational|commercial|transactional|navigational`
- `--contains "term"` - Include keywords containing term
- `--excludes "term"` - Exclude keywords containing term

**Wildcard Support**:
```bash
/keyword-research "best * for dogs"
# Returns: best food for dogs, best toys for dogs, etc.
```

### /autocomplete-research

Google autocomplete expansion for long-tail keywords.

```bash
/autocomplete-research "how to lose weight"
```

**Output**: Long-tail variations from Google's autocomplete suggestions

### /keyword-research-extended

Full SERP analysis with weakness detection and KeywordScore.

```bash
/keyword-research-extended "best seo tools"
```

**Output**: All basic metrics + KeywordScore, Domain Score, Page Score, Weakness Count, Weakness Types

**Additional Options**:
- `--quick` - Skip weakness detection (faster, cheaper)
- `--full` - Complete analysis (default)
- `--ahrefs` - Include Ahrefs DR/UR metrics
- `--domain example.com` - Domain research mode
- `--competitor example.com` - Competitor research mode
- `--gap yourdomain.com,competitor.com` - Keyword gap analysis

## Output Format

### Research Results (Markdown Table)

```
| Keyword                  | Volume  | CPC    | KD  | Intent       |
|--------------------------|---------|--------|-----|--------------|
| best seo tools 2025      | 12,100  | $4.50  | 45  | Commercial   |
| free seo tools           |  8,100  | $2.10  | 38  | Commercial   |
| seo tools for beginners  |  2,400  | $3.20  | 28  | Informational|
```

### Extended Results (Full Analysis)

```
| Keyword              | Vol    | KD  | KS  | Weaknesses | Weakness Types                        | DS  | PS  | DR  |
|----------------------|--------|-----|-----|------------|---------------------------------------|-----|-----|-----|
| best seo tools       | 12.1K  | 45  | 72  | 5          | Low DS, Old Content, Slow Page, ...   | 23  | 15  | 31  |
| free seo tools       |  8.1K  | 38  | 68  | 4          | No Backlinks, Non-HTTPS, ...          | 18  | 12  | 24  |
```

### Competitor/Gap Results (Additional Columns)

```
| Keyword              | Vol    | KD  | Position | Est Traffic | Ranking URL                    |
|----------------------|--------|-----|----------|-------------|--------------------------------|
| best seo tools       | 12.1K  | 45  | 3        | 2,450       | example.com/blog/seo-tools     |
```

## KeywordScore Algorithm

KeywordScore (0-100) measures ranking opportunity based on SERP weaknesses.

### Scoring Components

| Component | Points |
|-----------|--------|
| Standard weaknesses (13 types) | +1 each |
| Unmatched Intent (1 word missing) | +4 |
| Unmatched Intent (2+ words missing) | +7 |
| Search Volume 101-1,000 | +1 |
| Search Volume 1,001-5,000 | +2 |
| Search Volume 5,000+ | +3 |
| Keyword Difficulty 0 | +3 |
| Keyword Difficulty 1-15 | +2 |
| Keyword Difficulty 16-30 | +1 |
| Low Average Domain Score | Variable |
| Individual Low DS (position-weighted) | Variable |
| SERP Features (non-organic) | -1 each (max -3) |

### Score Interpretation

| Score | Opportunity Level |
|-------|-------------------|
| 90-100 | Exceptional - multiple significant weaknesses |
| 70-89 | Strong - several exploitable weaknesses |
| 50-69 | Moderate - some weaknesses present |
| 30-49 | Challenging - few weaknesses |
| 0-29 | Very difficult - highly competitive |

## SERP Weakness Detection

### 17 Weakness Types (4 Categories)

#### Domain & Authority (3)

| Weakness | Threshold | Description |
|----------|-----------|-------------|
| Low Domain Score | DS ≤ 10 | Weak domain authority |
| Low Page Score | PS ≤ 0 | Weak page authority |
| No Backlinks | 0 backlinks | Page ranks without links |

#### Technical SEO (7)

| Weakness | Threshold | Description |
|----------|-----------|-------------|
| Slow Page Speed | > 3000ms | Poor load performance |
| High Spam Score | ≥ 50 | Spammy domain signals |
| Non-HTTPS | HTTP only | Missing SSL security |
| Broken Page | 4xx/5xx | Technical errors |
| Flash Code | Present | Outdated technology |
| Frames | Present | Outdated layout |
| Non-Canonical | Missing | Duplicate content issues |

#### Content Quality (4)

| Weakness | Threshold | Description |
|----------|-----------|-------------|
| Old Content | > 2 years | Stale information |
| Title-Content Mismatch | Detected | Poor optimization |
| Keyword Not in Headings | Missing | Suboptimal structure |
| No Heading Tags | None | Poor content structure |

#### SERP Composition (1)

| Weakness | Threshold | Description |
|----------|-----------|-------------|
| UGC-Heavy Results | 3+ UGC sites | Reddit, Quora dominate |

#### Intent Analysis (1)

| Weakness | Detection | Description |
|----------|-----------|-------------|
| Unmatched Intent | Title analysis | Content doesn't match query |

## Location & Language

### Default Behavior

1. First run: Prompt user to confirm US/English or select alternative
2. Subsequent runs: Use saved preference
3. Override with `--location` flag

### Supported Locales

| Code | Location | Language |
|------|----------|----------|
| `us-en` | United States | English |
| `uk-en` | United Kingdom | English |
| `ca-en` | Canada | English |
| `au-en` | Australia | English |
| `de-de` | Germany | German |
| `fr-fr` | France | French |
| `es-es` | Spain | Spanish |
| `custom` | Enter location code | Any |

### Configuration

Preferences saved to `~/.config/aidevops/keyword-research.json`:

```json
{
  "default_locale": "us-en",
  "default_provider": "dataforseo",
  "default_limit": 100,
  "include_ahrefs": false,
  "csv_directory": "~/Downloads"
}
```

## Provider Configuration

### DataForSEO (Primary)

Full-featured provider with all capabilities.

**Endpoints Used**:
- `dataforseo_labs/google/keyword_suggestions/live` - Keyword expansion
- `dataforseo_labs/google/ranked_keywords/live` - Competitor keywords
- `dataforseo_labs/google/domain_intersection/live` - Keyword gap
- `backlinks/summary/live` - Domain/Page scores
- `serp/google/organic/live` - SERP analysis
- `onpage/instant_pages` - Page speed, technical analysis

**Required Env Vars**:
```bash
DATAFORSEO_USERNAME="your_username"
DATAFORSEO_PASSWORD="your_password"
```

### Serper (Alternative)

Faster, simpler API for basic research.

**Endpoints Used**:
- `search` - SERP data
- `autocomplete` - Long-tail suggestions

**Required Env Vars**:
```bash
SERPER_API_KEY="your_api_key"
```

### Ahrefs (Optional)

Premium metrics for Domain Rating (DR) and URL Rating (UR).

**Endpoints Used**:
- `domain-rating` - DR metric
- `url-rating` - UR metric

**Required Env Vars**:
```bash
AHREFS_API_KEY="your_api_key"
```

## Workflow Examples

### Basic Keyword Research

```bash
# Expand seed keywords
/keyword-research "dog training, puppy training"

# With filters
/keyword-research "dog training" --min-volume 1000 --max-difficulty 40

# Export to CSV
/keyword-research "dog training" --csv
```

### Long-tail Discovery

```bash
# Autocomplete expansion
/autocomplete-research "how to train a puppy"

# Wildcard patterns
/keyword-research "best * for puppies"
```

### Competitive Analysis

```bash
# What keywords does competitor rank for?
/keyword-research-extended --competitor petco.com

# What keywords do they have that I don't?
/keyword-research-extended --gap mydogsite.com,petco.com

# Domain niche keywords
/keyword-research-extended --domain chewy.com
```

### Full SERP Analysis

```bash
# Complete analysis with weakness detection
/keyword-research-extended "dog training tips"

# Quick mode (no weakness detection)
/keyword-research-extended "dog training tips" --quick

# Include Ahrefs DR/UR
/keyword-research-extended "dog training tips" --ahrefs
```

## Result Limits & Pagination

### Default Behavior

1. Return first 100 results
2. Prompt: "Retrieved 100 keywords. Need more? Enter number (max 10,000) or press Enter to continue:"
3. If user enters number, fetch additional results
4. Continue until user presses Enter or max reached

### Credit Efficiency

| Results | Approximate Cost |
|---------|------------------|
| 100 | 1 credit |
| 500 | 5 credits |
| 1,000 | 10 credits |
| 5,000 | 50 credits |
| 10,000 | 100 credits |

## CSV Export

### File Location

Default: `~/Downloads/keyword-research-YYYYMMDD-HHMMSS.csv`

### CSV Columns

**Basic Research**:
```
Keyword,Volume,CPC,Difficulty,Intent
```

**Extended Research**:
```
Keyword,Volume,CPC,Difficulty,Intent,KeywordScore,DomainScore,PageScore,WeaknessCount,Weaknesses,DR,UR
```

**Competitor/Gap Research**:
```
Keyword,Volume,CPC,Difficulty,Intent,Position,EstTraffic,RankingURL
```

## Integration with SEO Workflow

### Recommended Process

1. **Discovery**: `/keyword-research` for broad expansion
2. **Long-tail**: `/autocomplete-research` for question keywords
3. **Competition**: `/keyword-research-extended --competitor` to spy on rivals
4. **Gaps**: `/keyword-research-extended --gap` to find opportunities
5. **Analysis**: `/keyword-research-extended` on top candidates for full SERP data
6. **Export**: `--csv` for content planning spreadsheets

### Combining with Other Tools

```bash
# Research keywords, then check page speed for top competitor URLs
/keyword-research-extended --competitor example.com
# Copy ranking URLs, then:
/pagespeed [url]

# Research keywords, then create content brief
/keyword-research-extended "target keyword"
# Use results to inform content strategy
```

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| "API key not found" | Run `/list-keys` to check credentials |
| "Rate limit exceeded" | Wait or switch provider with `--provider` |
| "No results found" | Try broader seed keywords or different locale |
| "Timeout" | Reduce `--limit` or use `--quick` mode |

### Provider Status

Check provider availability:
```bash
/list-keys --service dataforseo
/list-keys --service serper
/list-keys --service ahrefs
```

## Resources

- DataForSEO Docs: https://docs.dataforseo.com/v3/
- Serper Docs: https://serper.dev/docs
- Ahrefs API: https://ahrefs.com/api
