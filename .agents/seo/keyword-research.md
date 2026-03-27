---
mode: subagent
---
# Keyword Research

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Providers**: DataForSEO (primary), Serper (alternative), Ahrefs (optional DR/UR)
- **Webmaster Tools**: Google Search Console, Bing Webmaster Tools (owned sites)
- **Config**: `~/.config/aidevops/keyword-research.json`

| Mode | Command/Flag | Purpose |
|------|-------------|---------|
| Keyword Research | `/keyword-research` | Expand seed keywords |
| Autocomplete | `/autocomplete-research` | Google long-tail expansion |
| Domain Research | `--domain` | Keywords for a domain's niche |
| Competitor Research | `--competitor` | Keywords a competitor ranks for |
| Keyword Gap | `--gap` | Competitor keywords you don't rank for |
| Webmaster Tools | `webmaster <url>` | Keywords from GSC + Bing |

| Level | Flag | Data |
|-------|------|------|
| Quick | `--quick` | Volume, CPC, KD, Intent |
| Full | `--full` (default for extended) | + KeywordScore, Domain Score, 17 weaknesses |

<!-- AI-CONTEXT-END -->

## Commands

### /keyword-research

Basic keyword expansion from seed keywords.

```bash
/keyword-research "best seo tools, keyword research"
/keyword-research "best * for dogs"   # wildcard support
```

**Options**: `--limit N` (default: 100, max: 10,000) · `--provider dataforseo|serper|both` · `--csv` · `--min-volume N` · `--max-difficulty N` · `--intent informational|commercial|transactional|navigational` · `--contains "term"` · `--excludes "term"`

### /autocomplete-research

Google autocomplete expansion for long-tail keywords.

```bash
/autocomplete-research "how to lose weight"
```

### /keyword-research-extended

Full SERP analysis with weakness detection and KeywordScore.

```bash
/keyword-research-extended "best seo tools"
```

**Additional options**: `--quick` (skip weakness detection) · `--full` (default) · `--ahrefs` (DR/UR metrics) · `--domain example.com` · `--competitor example.com` · `--gap yourdomain.com,competitor.com`

## Output Format

```
# Basic
| Keyword                  | Volume  | CPC    | KD  | Intent        |
| best seo tools 2025      | 12,100  | $4.50  | 45  | Commercial    |

# Extended
| Keyword          | Vol   | KD  | KS  | Weaknesses | Weakness Types              | DS  | PS  | DR  |
| best seo tools   | 12.1K | 45  | 72  | 5          | Low DS, Old Content, ...    | 23  | 15  | 31  |

# Competitor/Gap
| Keyword          | Vol   | KD  | Position | Est Traffic | Ranking URL                |
| best seo tools   | 12.1K | 45  | 3        | 2,450       | example.com/blog/seo-tools |
```

**CSV columns** — Basic: `Keyword,Volume,CPC,Difficulty,Intent` · Extended: adds `KeywordScore,DomainScore,PageScore,WeaknessCount,Weaknesses,DR,UR` · Competitor/Gap: adds `Position,EstTraffic,RankingURL`

Default export path: `~/Downloads/keyword-research-YYYYMMDD-HHMMSS.csv`

## KeywordScore Algorithm

KeywordScore (0–100) measures ranking opportunity from SERP weaknesses.

| Component | Points |
|-----------|--------|
| Standard weaknesses (13 types) | +1 each |
| Unmatched Intent (1 word missing) | +4 |
| Unmatched Intent (2+ words missing) | +7 |
| Search Volume 101–1,000 / 1,001–5,000 / 5,000+ | +1 / +2 / +3 |
| Keyword Difficulty 0 / 1–15 / 16–30 | +3 / +2 / +1 |
| Low Average Domain Score | Variable |
| Individual Low DS (position-weighted) | Variable |
| SERP Features (non-organic) | −1 each (max −3) |

| Score | Opportunity |
|-------|-------------|
| 90–100 | Exceptional |
| 70–89 | Strong |
| 50–69 | Moderate |
| 30–49 | Challenging |
| 0–29 | Very difficult |

## SERP Weakness Detection (17 Types)

| Category | Weakness | Threshold |
|----------|----------|-----------|
| **Domain & Authority** | Low Domain Score | DS ≤ 10 |
| | Low Page Score | PS ≤ 0 |
| | No Backlinks | 0 backlinks |
| **Technical SEO** | Slow Page Speed | > 3000ms |
| | High Spam Score | ≥ 50 |
| | Non-HTTPS | HTTP only |
| | Broken Page | 4xx/5xx |
| | Flash Code | Present |
| | Frames | Present |
| | Non-Canonical | Missing |
| **Content Quality** | Old Content | > 2 years |
| | Title-Content Mismatch | Detected |
| | Keyword Not in Headings | Missing |
| | No Heading Tags | None |
| **SERP Composition** | UGC-Heavy Results | 3+ UGC sites |
| **Intent** | Unmatched Intent | Title analysis |

## Location & Language

First run: prompt user to confirm US/English or select alternative. Subsequent runs: use saved preference. Override with `--location`.

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

**DataForSEO** (primary) — endpoints: `dataforseo_labs/google/keyword_suggestions/live`, `ranked_keywords/live`, `domain_intersection/live`, `backlinks/summary/live`, `serp/google/organic/live`, `onpage/instant_pages`. Credentials: `DATAFORSEO_USERNAME` + `DATAFORSEO_PASSWORD`.

**Serper** (alternative) — faster, simpler. Endpoints: `search`, `autocomplete`. Credential: `SERPER_API_KEY`.

**Ahrefs** (optional) — premium DR/UR metrics. Endpoints: `domain-rating`, `url-rating`. Credential: `AHREFS_API_KEY`.

## Recommended Workflow

1. **Discovery**: `/keyword-research` — broad expansion
2. **Long-tail**: `/autocomplete-research` — question keywords
3. **Competition**: `/keyword-research-extended --competitor` — rival keywords
4. **Gaps**: `/keyword-research-extended --gap` — opportunities
5. **Analysis**: `/keyword-research-extended` — full SERP data on top candidates
6. **Export**: `--csv` — content planning spreadsheets

```bash
# Examples
/keyword-research "dog training" --min-volume 1000 --max-difficulty 40 --csv
/autocomplete-research "how to train a puppy"
/keyword-research-extended --competitor petco.com
/keyword-research-extended --gap mydogsite.com,petco.com
/keyword-research-extended "dog training tips" --ahrefs
```

## Result Limits

Default: 100 results, then prompt "Retrieved 100 keywords. Need more? Enter number (max 10,000) or press Enter to continue."

| Results | Approx. Cost |
|---------|-------------|
| 100 | 1 credit |
| 1,000 | 10 credits |
| 10,000 | 100 credits |

## Webmaster Tools Integration

Keywords from GSC + Bing enriched with DataForSEO volume/difficulty data.

```bash
keyword-research-helper.sh sites                                     # list verified sites
keyword-research-helper.sh webmaster https://example.com            # last 30 days
keyword-research-helper.sh webmaster https://example.com --days 90  # last 90 days
keyword-research-helper.sh webmaster https://example.com --no-enrich # skip enrichment
keyword-research-helper.sh webmaster https://example.com --csv      # export
```

**Output columns**: Keyword, Clicks, Impressions, CTR, Position, Volume, KD, CPC, Sources (GSC/Bing/Both)

**Google Search Console setup**: Cloud Console → enable "Search Console API" → create Service Account → download JSON key → add service account email to GSC with "Full" permissions. Set `GOOGLE_APPLICATION_CREDENTIALS="/path/to/key.json"`.

**Bing Webmaster Tools setup**: [bing.com/webmasters](https://www.bing.com/webmasters) → add/verify site → Settings → API Access → Generate API Key. Set `BING_WEBMASTER_API_KEY`.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "API key not found" | Run `/list-keys` to check credentials |
| "Rate limit exceeded" | Wait or switch provider with `--provider` |
| "No results found" | Try broader seeds or different locale |
| "Timeout" | Reduce `--limit` or use `--quick` |

Check availability: `/list-keys --service dataforseo|serper|ahrefs`
