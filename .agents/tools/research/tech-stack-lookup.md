---
name: tech-stack-lookup
description: Tech stack discovery orchestrator - detect technologies and find sites using specific tech
mode: subagent
model: sonnet
subagents:
  - providers/unbuilt
  - providers/crft-lookup
  - providers/openexplorer
  - providers/wappalyzer
---

# Tech Stack Lookup - Technology Discovery Orchestrator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Discover tech stacks of websites and find sites using specific technologies
- **Architecture**: Multi-provider orchestrator with result merging and caching
- **Modes**: Single-site lookup, reverse lookup (find sites by technology)

**Two Modes**:

1. **Single-Site Lookup** - Detect full tech stack of a URL
2. **Reverse Lookup** - Find websites using specific technologies

**Providers** (parallel execution):

- **Unbuilt.app** (`providers/unbuilt.md`) - Frontend/JS specialist (bundlers, frameworks, UI libs)
- **CRFT Lookup** (`providers/crft-lookup.md`) - 2500+ fingerprints + Lighthouse scores
- **OpenExplorer** (`providers/openexplorer.md`) - Open-source tech discovery
- **Wappalyzer OSS** (`providers/wappalyzer.md`) - Self-hosted fallback

**CLI**: `tech-stack-helper.sh [lookup|reverse|report|cache]`

**Slash Commands**:

- `/tech-stack <url>` - Single-site lookup
- `/tech-stack reverse <tech> [--region X] [--industry Y]` - Reverse lookup

**Cache**: SQLite in `~/.aidevops/.agent-workspace/tech-stacks/`

**Output Formats**: Terminal table, JSON, markdown report

<!-- AI-CONTEXT-END -->

## Architecture

The tech-stack-lookup orchestrator replicates BuiltWith.com capabilities using multiple open-source providers. It runs providers in parallel, merges results, deduplicates technologies, and caches everything in SQLite.

**Why Multiple Providers?**

Each provider has different strengths:

- **Unbuilt**: Best at frontend/JS detection (React, Vue, bundlers, state management)
- **CRFT Lookup**: Broadest fingerprint database (2500+ technologies)
- **OpenExplorer**: Community-driven, frequently updated
- **Wappalyzer OSS**: Self-hosted, works offline

Running all providers in parallel gives the most complete picture.

## Single-Site Lookup

Detect the full tech stack of a given URL.

**Usage**:

```bash
# Via helper script
tech-stack-helper.sh lookup https://example.com

# Via slash command
/tech-stack https://example.com

# With specific output format
tech-stack-helper.sh lookup https://example.com --format json
tech-stack-helper.sh lookup https://example.com --format markdown
```

**Detection Categories**:

- **Frontend**: Frameworks (React, Vue, Angular, Svelte), UI libraries, styling (Tailwind, Sass)
- **Backend**: Server frameworks, languages, runtime environments
- **Bundlers**: Webpack, Vite, Rollup, Parcel, esbuild
- **State Management**: Redux, MobX, Zustand, Pinia
- **CMS**: WordPress, Drupal, Contentful, Strapi
- **Analytics**: Google Analytics, Mixpanel, Plausible, Fathom
- **CDN**: Cloudflare, Fastly, Akamai, AWS CloudFront
- **Hosting**: Vercel, Netlify, AWS, GCP, self-hosted
- **Monitoring**: Sentry, Datadog, LogRocket, New Relic
- **Performance**: Lighthouse scores (via CRFT Lookup)

**Workflow**:

1. Check cache for recent results (default: 7 days)
2. If cache miss, dispatch all 4 providers in parallel
3. Wait for all providers to complete (timeout: 30s per provider)
4. Merge results using common schema
5. Deduplicate technologies (same tech detected by multiple providers)
6. Store merged result in SQLite cache
7. Return formatted output

**Provider Selection Logic**:

The orchestrator calls ALL providers by default for maximum coverage. You can filter providers:

```bash
# Only use Unbuilt (fastest, frontend-focused)
tech-stack-helper.sh lookup https://example.com --provider unbuilt

# Use multiple specific providers
tech-stack-helper.sh lookup https://example.com --provider unbuilt,crft

# Skip slow providers
tech-stack-helper.sh lookup https://example.com --skip openexplorer
```

**When to use specific providers**:

- **Unbuilt only**: When you only care about frontend/JS stack (fastest)
- **CRFT + Wappalyzer**: When you need broad coverage but Unbuilt/OpenExplorer are down
- **All providers**: Default - most complete results

## Result Merging Strategy

Each provider returns results in a common schema. The orchestrator merges them using these rules:

**Common Schema**:

```json
{
  "url": "https://example.com",
  "provider": "unbuilt",
  "timestamp": "2026-02-16T21:00:00Z",
  "technologies": [
    {
      "name": "React",
      "category": "frontend-framework",
      "version": "18.2.0",
      "confidence": "high"
    }
  ]
}
```

**Merge Rules**:

1. **Deduplication**: Same technology detected by multiple providers → keep highest confidence
2. **Version Conflicts**: Different versions detected → keep most specific version (e.g., "18.2.0" over "18.x")
3. **Category Normalization**: Map provider-specific categories to standard categories
4. **Confidence Scoring**: Aggregate confidence from multiple providers (2+ providers = high confidence)

**Example Merge**:

```text
Unbuilt:  React 18.2.0 (high confidence)
CRFT:     React 18.x (medium confidence)
Wappalyzer: React (low confidence)

Merged:   React 18.2.0 (high confidence, 3 providers)
```

**Conflict Resolution**:

- **Technology Name**: Use most specific name (e.g., "Next.js" over "React")
- **Version**: Use most specific version string
- **Category**: Use primary category if multiple detected
- **Confidence**: Average confidence scores, boost if 2+ providers agree

## Caching

Results are cached in SQLite to avoid redundant API calls and speed up repeated lookups.

**Cache Location**: `~/.aidevops/.agent-workspace/tech-stacks/cache.db`

**Cache Schema**:

```sql
CREATE TABLE tech_stacks (
  url TEXT PRIMARY KEY,
  technologies TEXT,  -- JSON array
  providers TEXT,     -- JSON array of provider names
  timestamp INTEGER,
  ttl INTEGER DEFAULT 604800  -- 7 days in seconds
);
```

**Cache Commands**:

```bash
# Check cache status
tech-stack-helper.sh cache status

# Clear cache for specific URL
tech-stack-helper.sh cache clear https://example.com

# Clear all cache
tech-stack-helper.sh cache clear --all

# Set custom TTL (in seconds)
tech-stack-helper.sh lookup https://example.com --ttl 86400  # 1 day
```

**Cache Invalidation**:

- **TTL Expiry**: Default 7 days (configurable)
- **Manual Clear**: `cache clear` command
- **Provider Update**: When provider fingerprints are updated, cache is auto-invalidated

**Cache Hit Behavior**:

- If cache hit and not expired → return cached result immediately
- If cache hit but expired → refresh in background, return stale result
- If cache miss → fetch from all providers

## Output Formats

The orchestrator supports three output formats.

### Terminal Table (Default)

```bash
tech-stack-helper.sh lookup https://example.com
```

```text
Tech Stack for https://example.com
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Category              Technology           Version    Confidence  Providers
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Frontend Framework    React                18.2.0     High        3
Bundler               Vite                 4.3.9      High        2
State Management      Redux Toolkit        1.9.5      Medium      1
Styling               Tailwind CSS         3.3.0      High        3
Analytics             Google Analytics 4   -          High        2
CDN                   Cloudflare           -          High        2
Hosting               Vercel               -          Medium      1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Detected by: Unbuilt, CRFT Lookup, Wappalyzer (3/4 providers)
Cache: Fresh (retrieved 2 minutes ago)
```

### JSON

```bash
tech-stack-helper.sh lookup https://example.com --format json
```

```json
{
  "url": "https://example.com",
  "timestamp": "2026-02-16T21:00:00Z",
  "cache_hit": false,
  "providers": ["unbuilt", "crft", "wappalyzer"],
  "technologies": [
    {
      "name": "React",
      "category": "frontend-framework",
      "version": "18.2.0",
      "confidence": "high",
      "detected_by": ["unbuilt", "crft", "wappalyzer"]
    }
  ]
}
```

### Markdown Report

```bash
tech-stack-helper.sh lookup https://example.com --format markdown
```

```markdown
# Tech Stack Report: example.com

**Generated**: 2026-02-16 21:00:00
**Providers**: Unbuilt, CRFT Lookup, Wappalyzer (3/4)

## Frontend

- **React** 18.2.0 (High confidence, 3 providers)
- **Tailwind CSS** 3.3.0 (High confidence, 3 providers)

## Build Tools

- **Vite** 4.3.9 (High confidence, 2 providers)

## State Management

- **Redux Toolkit** 1.9.5 (Medium confidence, 1 provider)

## Analytics

- **Google Analytics 4** (High confidence, 2 providers)

## Infrastructure

- **CDN**: Cloudflare (High confidence, 2 providers)
- **Hosting**: Vercel (Medium confidence, 1 provider)
```

## Slash Command Usage

The `/tech-stack` slash command provides quick access to tech stack lookup.

**Single-Site Lookup**:

```bash
/tech-stack https://example.com
```

**With Options**:

```bash
# Specific output format
/tech-stack https://example.com --format json

# Use specific providers
/tech-stack https://example.com --provider unbuilt,crft

# Force cache refresh
/tech-stack https://example.com --refresh
```

**Reverse Lookup**:

```bash
# Find sites using React
/tech-stack reverse React

# With filters
/tech-stack reverse React --region US --industry ecommerce

# With traffic tier
/tech-stack reverse Next.js --traffic high --limit 50
```

**Command Aliases**:

- `/tech-stack` → Full command
- `/tech` → Short alias
- `/stack` → Alternative alias

## Reverse Lookup Workflow

Find websites using specific technologies. This replicates BuiltWith's "Technology Usage" feature.

**Usage**:

```bash
# Find sites using React
tech-stack-helper.sh reverse React

# With filters
tech-stack-helper.sh reverse "Next.js" --region US --industry ecommerce --limit 100

# Multiple technologies (AND logic)
tech-stack-helper.sh reverse "React,Tailwind CSS" --operator and

# Multiple technologies (OR logic)
tech-stack-helper.sh reverse "Vue,Angular,Svelte" --operator or
```

**Data Sources** (in priority order):

1. **HTTP Archive** (primary) - BigQuery dataset with millions of crawled sites
2. **Wappalyzer Public Datasets** - Community-contributed data
3. **BuiltWith Trends** (free tier) - Limited but high-quality data
4. **Chrome UX Report (CrUX)** - Traffic and performance data

**Filters**:

- `--region <region>` - Geographic filter (US, EU, APAC, etc.)
- `--industry <industry>` - Industry vertical (ecommerce, saas, media, etc.)
- `--keywords <terms>` - Filter by site content keywords
- `--traffic <tier>` - Traffic tier (low, medium, high, very-high)
- `--limit <n>` - Max results (default: 50)

**Output**:

```text
Sites Using React
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
URL                          Region  Industry   Traffic   Version
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
https://example.com          US      SaaS       High      18.2.0
https://another.com          EU      Ecommerce  Medium    17.0.2
https://third.com            APAC    Media      High      18.1.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Found 3 sites using React (filtered from 1.2M total)
Data source: HTTP Archive (2026-02-01 snapshot)
```

**Reverse Lookup Cache**:

Reverse lookup results are cached aggressively (30 days default) since HTTP Archive data updates monthly.

```bash
# Check reverse lookup cache
tech-stack-helper.sh cache reverse-status

# Clear reverse lookup cache
tech-stack-helper.sh cache clear-reverse
```

**HTTP Archive Query**:

The orchestrator queries HTTP Archive via BigQuery API:

```sql
SELECT
  url,
  technologies,
  region,
  traffic_tier
FROM `httparchive.technologies.2026_02_01`
WHERE technologies LIKE '%React%'
  AND region = 'US'
  AND traffic_tier = 'high'
LIMIT 100
```

**Rate Limits**:

- BigQuery free tier: 1TB queries/month (sufficient for most use cases)
- Wappalyzer API: 100 requests/day (free tier)
- BuiltWith Trends: 50 requests/day (free tier)

## Provider Subagents

Each provider has its own subagent with detailed implementation docs.

**Read these on-demand when you need provider-specific details**:

| Provider | Subagent | Strengths |
|----------|----------|-----------|
| Unbuilt.app | `providers/unbuilt.md` | Frontend/JS specialist, CLI available |
| CRFT Lookup | `providers/crft-lookup.md` | 2500+ fingerprints, Lighthouse scores |
| OpenExplorer | `providers/openexplorer.md` | Open-source, community-driven |
| Wappalyzer OSS | `providers/wappalyzer.md` | Self-hosted, offline capable |

**When to read provider docs**:

- Debugging provider-specific issues
- Understanding detection capabilities
- Configuring provider-specific options
- Contributing provider improvements

## Common Workflows

**Quick Frontend Stack Check**:

```bash
# Fastest - Unbuilt only
tech-stack-helper.sh lookup https://example.com --provider unbuilt
```

**Full Comprehensive Scan**:

```bash
# All providers, markdown report
tech-stack-helper.sh lookup https://example.com --format markdown > report.md
```

**Competitive Analysis**:

```bash
# Find all sites using competitor's stack
tech-stack-helper.sh reverse "Next.js,Vercel,Tailwind CSS" --operator and --limit 200
```

**Technology Migration Research**:

```bash
# Find sites that migrated from Vue to React (compare snapshots)
tech-stack-helper.sh reverse Vue --snapshot 2025-01-01 > vue-sites.txt
tech-stack-helper.sh reverse React --snapshot 2026-02-01 > react-sites.txt
# Diff the results to find migrations
```

**Batch Lookup**:

```bash
# Lookup multiple sites from file
cat urls.txt | xargs -I {} tech-stack-helper.sh lookup {} --format json >> results.jsonl
```

## Troubleshooting

**Provider Timeouts**:

If a provider times out (30s default), the orchestrator continues with other providers.

```bash
# Increase timeout
tech-stack-helper.sh lookup https://example.com --timeout 60

# Skip problematic provider
tech-stack-helper.sh lookup https://example.com --skip openexplorer
```

**Cache Issues**:

```bash
# Force refresh (bypass cache)
tech-stack-helper.sh lookup https://example.com --refresh

# Clear cache and retry
tech-stack-helper.sh cache clear https://example.com
tech-stack-helper.sh lookup https://example.com
```

**Missing Technologies**:

If expected technologies are not detected:

1. Check which providers ran: `--format json` shows `detected_by` field
2. Try specific provider: `--provider unbuilt` (best for frontend)
3. Check provider docs for known limitations
4. File issue with provider if it's a detection gap

**Reverse Lookup No Results**:

```bash
# Check if technology name is correct
tech-stack-helper.sh reverse "React" --limit 1  # Should always return results

# Try broader search
tech-stack-helper.sh reverse "React" --region all --traffic all

# Check data source status
tech-stack-helper.sh cache reverse-status
```

## Performance

**Single-Site Lookup**:

- Cache hit: <100ms
- Cache miss (all providers): 5-15s
- Single provider: 2-5s

**Reverse Lookup**:

- Cache hit: <100ms
- Cache miss (HTTP Archive): 2-10s depending on result size
- BigQuery query: 1-5s

**Optimization Tips**:

- Use cache aggressively (default 7 days is good)
- For frontend-only checks, use `--provider unbuilt` (fastest)
- Batch lookups with parallel execution: `xargs -P 4`
- Pre-warm cache for known URLs

## Integration

**With Other Agents**:

```bash
# SEO analysis + tech stack
/seo audit https://example.com
/tech-stack https://example.com

# Content research + tech stack
"Research the AI video generation niche, then analyze the tech stacks of top 10 competitors"

# WordPress site analysis
/wordpress analyze https://example.com
/tech-stack https://example.com
```

**Programmatic Usage**:

```bash
# JSON output for scripting
tech_stack=$(tech-stack-helper.sh lookup https://example.com --format json)
echo "$tech_stack" | jq '.technologies[] | select(.category == "frontend-framework")'
```

## Future Enhancements

**Planned Features** (see TODO.md for task IDs):

- Historical tracking (detect tech stack changes over time)
- Vulnerability scanning (cross-reference with CVE databases)
- Performance correlation (tech stack vs Lighthouse scores)
- Cost estimation (hosting/CDN costs based on detected stack)
- Migration recommendations (suggest modern alternatives)

**Provider Additions**:

- BuiltWith API integration (paid tier)
- Shodan integration (server-side tech detection)
- SecurityHeaders.com integration (security posture)
- Custom fingerprint database (user-contributed patterns)

## Related Documentation

- **Provider Subagents**: `providers/unbuilt.md`, `providers/crft-lookup.md`, `providers/openexplorer.md`, `providers/wappalyzer.md`
- **Reverse Lookup Deep Dive**: Task t1068 (HTTP Archive integration)
- **Slash Commands**: `scripts/commands/tech-stack.md`
- **Helper Script**: `scripts/tech-stack-helper.sh`
- **Caching Strategy**: `memory/README.md` (SQLite patterns)
