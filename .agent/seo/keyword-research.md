---
mode: subagent
---
# Keyword Research

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Comprehensive keyword research with SERP weakness detection and opportunity scoring
- **Providers**: DataForSEO (primary), Serper (alternative), Ahrefs (optional DR/UR)
- **Webmaster Tools**: Google Search Console, Bing Webmaster Tools (for owned sites)
- **Commands**: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/webmaster-keywords`
- **Config**: `~/.config/aidevops/keyword-research.json`

**Research Modes**:

| Mode | Flag | Purpose |
|------|------|---------|
| Keyword Research | (default) | Expand seed keywords with related suggestions |
| Autocomplete | `/autocomplete-research` | Google autocomplete long-tail expansion |
| Domain Research | `--domain` | Keywords associated with a domain's niche |
| Competitor Research | `--competitor` | Exact keywords a competitor ranks for |
| Keyword Gap | `--gap` | Keywords competitor ranks for that you don't |
| Webmaster Tools | `webmaster <url>` | Keywords from GSC + Bing for your verified sites |

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
```text

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
```text

### /autocomplete-research

Google autocomplete expansion for long-tail keywords.

```bash
/autocomplete-research "how to lose weight"
```text

**Output**: Long-tail variations from Google's autocomplete suggestions

### /keyword-research-extended

Full SERP analysis with weakness detection and KeywordScore.

```bash
/keyword-research-extended "best seo tools"
```text

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

```text
| Keyword                  | Volume  | CPC    | KD  | Intent       |
|--------------------------|---------|--------|-----|--------------|
| best seo tools 2025      | 12,100  | $4.50  | 45  | Commercial   |
| free seo tools           |  8,100  | $2.10  | 38  | Commercial   |
| seo tools for beginners  |  2,400  | $3.20  | 28  | Informational|
```text

### Extended Results (Full Analysis)

```text
| Keyword              | Vol    | KD  | KS  | Weaknesses | Weakness Types                        | DS  | PS  | DR  |
|----------------------|--------|-----|-----|------------|---------------------------------------|-----|-----|-----|
| best seo tools       | 12.1K  | 45  | 72  | 5          | Low DS, Old Content, Slow Page, ...   | 23  | 15  | 31  |
| free seo tools       |  8.1K  | 38  | 68  | 4          | No Backlinks, Non-HTTPS, ...          | 18  | 12  | 24  |
```text

### Competitor/Gap Results (Additional Columns)

```text
| Keyword              | Vol    | KD  | Position | Est Traffic | Ranking URL                    |
|----------------------|--------|-----|----------|-------------|--------------------------------|
| best seo tools       | 12.1K  | 45  | 3        | 2,450       | example.com/blog/seo-tools     |
```text

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
```text

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
```text

### Serper (Alternative)

Faster, simpler API for basic research.

**Endpoints Used**:
- `search` - SERP data
- `autocomplete` - Long-tail suggestions

**Required Env Vars**:

```bash
SERPER_API_KEY="your_api_key"
```text

### Ahrefs (Optional)

Premium metrics for Domain Rating (DR) and URL Rating (UR).

**Endpoints Used**:
- `domain-rating` - DR metric
- `url-rating` - UR metric

**Required Env Vars**:

```bash
AHREFS_API_KEY="your_api_key"
```text

## Workflow Examples

### Basic Keyword Research

```bash
# Expand seed keywords
/keyword-research "dog training, puppy training"

# With filters
/keyword-research "dog training" --min-volume 1000 --max-difficulty 40

# Export to CSV
/keyword-research "dog training" --csv
```text

### Long-tail Discovery

```bash
# Autocomplete expansion
/autocomplete-research "how to train a puppy"

# Wildcard patterns
/keyword-research "best * for puppies"
```text

### Competitive Analysis

```bash
# What keywords does competitor rank for?
/keyword-research-extended --competitor petco.com

# What keywords do they have that I don't?
/keyword-research-extended --gap mydogsite.com,petco.com

# Domain niche keywords
/keyword-research-extended --domain chewy.com
```text

### Full SERP Analysis

```bash
# Complete analysis with weakness detection
/keyword-research-extended "dog training tips"

# Quick mode (no weakness detection)
/keyword-research-extended "dog training tips" --quick

# Include Ahrefs DR/UR
/keyword-research-extended "dog training tips" --ahrefs
```text

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

```text
Keyword,Volume,CPC,Difficulty,Intent
```text

**Extended Research**:

```text
Keyword,Volume,CPC,Difficulty,Intent,KeywordScore,DomainScore,PageScore,WeaknessCount,Weaknesses,DR,UR
```text

**Competitor/Gap Research**:

```text
Keyword,Volume,CPC,Difficulty,Intent,Position,EstTraffic,RankingURL
```text

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
```text

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
```text

## Webmaster Tools Integration

### /webmaster-keywords

Get keywords from Google Search Console and Bing Webmaster Tools for your verified sites, enriched with DataForSEO volume/difficulty data.

```bash
# List verified sites
keyword-research-helper.sh sites

# Get keywords for a site (last 30 days)
keyword-research-helper.sh webmaster https://example.com

# Last 90 days
keyword-research-helper.sh webmaster https://example.com --days 90

# Without enrichment (faster, no DataForSEO credits)
keyword-research-helper.sh webmaster https://example.com --no-enrich

# Export to CSV
keyword-research-helper.sh webmaster https://example.com --csv
```text

**Output**: Keyword, Clicks, Impressions, CTR, Position, Volume, KD, CPC, Sources (GSC/Bing/Both)

### Data Sources

| Source | Data Provided |
|--------|---------------|
| Google Search Console | Clicks, Impressions, CTR, Position |
| Bing Webmaster Tools | Clicks, Impressions, Position |
| DataForSEO (enrichment) | Volume, CPC, Keyword Difficulty |

### Benefits

1. **Real Performance Data**: Actual clicks/impressions from search engines
2. **Combined View**: GSC + Bing data in one table
3. **Enriched Metrics**: Add volume/difficulty from DataForSEO
4. **Opportunity Detection**: Find high-impression, low-CTR keywords to optimize
5. **Position Tracking**: Monitor ranking changes over time

### Google Search Console Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or use existing)
3. Enable "Search Console API"
4. Create a Service Account → Download JSON key
5. In [Google Search Console](https://search.google.com/search-console), add the service account email as a user with "Full" permissions

**Environment variables**:

```bash
# Option 1: Service account file (recommended)
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"

# Option 2: Access token (for testing)
export GSC_ACCESS_TOKEN="your_access_token"
```text

### Bing Webmaster Tools Setup

1. Go to [Bing Webmaster Tools](https://www.bing.com/webmasters)
2. Sign in with Microsoft/Google/Facebook account
3. Add and verify your site(s)
4. Click **Settings** → **API Access**
5. Accept Terms → Click **Generate API Key**

**Environment variable**:

```bash
export BING_WEBMASTER_API_KEY="your_api_key"
```text

### Workflow Example

```bash
# 1. List your verified sites
keyword-research-helper.sh sites

# 2. Get keywords for your site
keyword-research-helper.sh webmaster https://mysite.com --days 30

# 3. Find optimization opportunities (high impressions, low CTR)
keyword-research-helper.sh webmaster https://mysite.com | sort -t'|' -k3 -rn | head -20

# 4. Research competitors for those keywords
keyword-research-helper.sh extended --competitor competitor.com

# 5. Export for content planning
keyword-research-helper.sh webmaster https://mysite.com --csv
```text

## Resources

- DataForSEO Docs: https://docs.dataforseo.com/v3/
- Serper Docs: https://serper.dev/docs
- Ahrefs API: https://ahrefs.com/api
- Google Search Console API: https://developers.google.com/webmaster-tools
- Bing Webmaster API: https://learn.microsoft.com/en-us/bingwebmaster/
