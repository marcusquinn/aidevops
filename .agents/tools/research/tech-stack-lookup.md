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

- `/tech-stack <url>` — Single-site lookup (aliases: `/tech`, `/stack`)
- `/tech-stack reverse <tech> [--region X] [--industry Y]` — Reverse lookup

**Cache**: SQLite in `~/.aidevops/.agent-workspace/tech-stacks/`

<!-- AI-CONTEXT-END -->

## Single-Site Lookup

```bash
tech-stack-helper.sh lookup https://example.com
tech-stack-helper.sh lookup https://example.com --format json
tech-stack-helper.sh lookup https://example.com --format markdown

# Provider filtering
tech-stack-helper.sh lookup https://example.com --provider unbuilt        # Frontend only (fastest)
tech-stack-helper.sh lookup https://example.com --provider unbuilt,crft   # Specific providers
tech-stack-helper.sh lookup https://example.com --skip openexplorer        # Skip slow providers
```

**Detection Categories**: Frontend frameworks, backend, bundlers, state management, CMS, analytics, CDN, hosting, monitoring, performance (Lighthouse via CRFT).

**Workflow**: Check cache (7-day TTL) → dispatch all providers in parallel (30s timeout each) → merge results → deduplicate → cache → return.

## Result Merging

Common schema per provider:

```json
{
  "url": "https://example.com",
  "provider": "unbuilt",
  "technologies": [{"name": "React", "category": "frontend-framework", "version": "18.2.0", "confidence": "high"}]
}
```

**Merge rules**:
1. Same tech from multiple providers → keep highest confidence
2. Version conflicts → keep most specific (e.g., "18.2.0" over "18.x")
3. Category normalization → map to standard categories
4. 2+ providers agreeing → boost to high confidence

## Caching

```sql
CREATE TABLE tech_stacks (
  url TEXT PRIMARY KEY,
  technologies TEXT,  -- JSON array
  providers TEXT,     -- JSON array of provider names
  timestamp INTEGER,
  ttl INTEGER DEFAULT 604800  -- 7 days in seconds
);
```

```bash
tech-stack-helper.sh cache status
tech-stack-helper.sh cache clear https://example.com
tech-stack-helper.sh cache clear --all
tech-stack-helper.sh lookup https://example.com --ttl 86400  # Custom TTL
tech-stack-helper.sh lookup https://example.com --refresh    # Force refresh
```

Cache hit behavior: fresh → return immediately; expired → refresh in background, return stale; miss → fetch all providers.

## Output Formats

```bash
# Terminal table (default)
tech-stack-helper.sh lookup https://example.com

# JSON (for scripting)
tech_stack=$(tech-stack-helper.sh lookup https://example.com --format json)
echo "$tech_stack" | jq '.technologies[] | select(.category == "frontend-framework")'

# Markdown report
tech-stack-helper.sh lookup https://example.com --format markdown > report.md
```

## Reverse Lookup

Find websites using specific technologies (replicates BuiltWith "Technology Usage").

```bash
tech-stack-helper.sh reverse React
tech-stack-helper.sh reverse "Next.js" --region US --industry ecommerce --limit 100
tech-stack-helper.sh reverse "React,Tailwind CSS" --operator and   # AND logic
tech-stack-helper.sh reverse "Vue,Angular,Svelte" --operator or    # OR logic
```

**Filters**: `--region`, `--industry`, `--keywords`, `--traffic <low|medium|high|very-high>`, `--limit <n>` (default 50)

**Data Sources** (priority order):
1. HTTP Archive (BigQuery) — millions of crawled sites
2. Wappalyzer Public Datasets
3. BuiltWith Trends (free tier, limited)
4. Chrome UX Report (CrUX) — traffic/performance data

**HTTP Archive Query**:

```sql
SELECT url, technologies, region, traffic_tier
FROM `httparchive.technologies.2026_02_01`
WHERE EXISTS(SELECT 1 FROM UNNEST(technologies) tech WHERE tech.name = 'React')
  AND region = 'US' AND traffic_tier = 'high'
LIMIT 100
```

**Rate Limits**: BigQuery free tier 1TB/month; Wappalyzer API 100 req/day; BuiltWith Trends 50 req/day.

**Reverse lookup cache**: 30-day TTL (HTTP Archive updates monthly).

```bash
tech-stack-helper.sh cache reverse-status
tech-stack-helper.sh cache clear-reverse
```

## Provider Subagents

Read on-demand for provider-specific details:

| Provider | Subagent | Strengths |
|----------|----------|-----------|
| Unbuilt.app | `providers/unbuilt.md` | Frontend/JS specialist, CLI available |
| CRFT Lookup | `providers/crft-lookup.md` | 2500+ fingerprints, Lighthouse scores |
| OpenExplorer | `providers/openexplorer.md` | Open-source, community-driven |
| Wappalyzer OSS | `providers/wappalyzer.md` | Self-hosted, offline capable |

## Common Workflows

```bash
# Quick frontend check (fastest)
tech-stack-helper.sh lookup https://example.com --provider unbuilt

# Full comprehensive scan
tech-stack-helper.sh lookup https://example.com --format markdown > report.md

# Competitive analysis
tech-stack-helper.sh reverse "Next.js,Vercel,Tailwind CSS" --operator and --limit 200

# Batch lookup
cat urls.txt | xargs -I {} tech-stack-helper.sh lookup {} --format json >> results.jsonl

# SEO + tech stack
/seo audit https://example.com && /tech-stack https://example.com
```

## Troubleshooting

**Provider timeouts** (30s default):
```bash
tech-stack-helper.sh lookup https://example.com --timeout 60
tech-stack-helper.sh lookup https://example.com --skip openexplorer
```

**Missing technologies**: Use `--format json` to check `detected_by` field; try `--provider unbuilt` for frontend; check provider docs for known limitations.

**Reverse lookup no results**:
```bash
tech-stack-helper.sh reverse "React" --limit 1          # Verify tech name
tech-stack-helper.sh reverse "React" --region all --traffic all  # Broaden search
tech-stack-helper.sh cache reverse-status               # Check data source
```

## Performance

| Operation | Cache Hit | Cache Miss |
|-----------|-----------|------------|
| Single-site (all providers) | <100ms | 5-15s |
| Single-site (one provider) | <100ms | 2-5s |
| Reverse lookup | <100ms | 2-10s |

Tips: Use cache aggressively; `--provider unbuilt` for frontend-only; batch with `xargs -P 4`.

## Related Documentation

- **Provider Subagents**: `providers/unbuilt.md`, `providers/crft-lookup.md`, `providers/openexplorer.md`, `providers/wappalyzer.md`
- **Reverse Lookup**: Task t1068 (HTTP Archive integration)
- **Slash Commands**: `scripts/commands/tech-stack.md`
- **Helper Script**: `scripts/tech-stack-helper.sh`
- **Caching Strategy**: `memory/README.md` (SQLite patterns)
