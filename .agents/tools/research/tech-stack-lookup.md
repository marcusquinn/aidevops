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
- **CLI**: `tech-stack-helper.sh [lookup|reverse|report|cache]`
- **Cache**: SQLite in `~/.aidevops/.agent-workspace/tech-stacks/`

**Two Modes**:
1. **Single-Site Lookup** — Detect full tech stack of a URL
2. **Reverse Lookup** — Find websites using specific technologies

**Providers** (parallel execution):
- **Unbuilt.app** (`providers/unbuilt.md`) — Frontend/JS specialist (bundlers, frameworks, UI libs)
- **CRFT Lookup** (`providers/crft-lookup.md`) — 2500+ fingerprints + Lighthouse scores
- **OpenExplorer** (`providers/openexplorer.md`) — Open-source tech discovery
- **Wappalyzer OSS** (`providers/wappalyzer.md`) — Self-hosted fallback

**Slash Commands**:
- `/tech-stack <url>` — Single-site lookup
- `/tech-stack reverse <tech> [--region X] [--industry Y]` — Reverse lookup
- Aliases: `/tech`, `/stack`

**Output Formats**: Terminal table (default), JSON (`--format json`), markdown (`--format markdown`)

<!-- AI-CONTEXT-END -->

## Single-Site Lookup

```bash
tech-stack-helper.sh lookup https://example.com
tech-stack-helper.sh lookup https://example.com --format json
tech-stack-helper.sh lookup https://example.com --provider unbuilt  # fastest, frontend-only
tech-stack-helper.sh lookup https://example.com --skip openexplorer
```

**Detection categories**: Frontend frameworks, backend, bundlers, state management, CMS, analytics, CDN, hosting, monitoring, performance.

**Workflow**: Check cache (7-day TTL) → dispatch all providers in parallel (30s timeout each) → merge + deduplicate → cache → return.

## Result Merging

**Common schema**:

```json
{
  "url": "https://example.com",
  "provider": "unbuilt",
  "timestamp": "2026-02-16T21:00:00Z",
  "technologies": [
    { "name": "React", "category": "frontend-framework", "version": "18.2.0", "confidence": "high" }
  ]
}
```

**Merge rules**:
1. Same tech from multiple providers → keep highest confidence
2. Version conflicts → keep most specific (e.g., `18.2.0` over `18.x`)
3. Category normalization → map to standard categories
4. 2+ providers agreeing → high confidence

## Caching

**Location**: `~/.aidevops/.agent-workspace/tech-stacks/cache.db`

```sql
CREATE TABLE tech_stacks (
  url TEXT PRIMARY KEY,
  technologies TEXT,  -- JSON array
  providers TEXT,     -- JSON array of provider names
  timestamp INTEGER,
  ttl INTEGER DEFAULT 604800  -- 7 days
);
```

```bash
tech-stack-helper.sh cache status
tech-stack-helper.sh cache clear https://example.com
tech-stack-helper.sh cache clear --all
tech-stack-helper.sh lookup https://example.com --ttl 86400  # 1 day
tech-stack-helper.sh lookup https://example.com --refresh    # bypass cache
```

Cache hit behavior: fresh → return immediately; expired → refresh in background, return stale; miss → fetch all providers.

## Reverse Lookup

Find websites using specific technologies (replicates BuiltWith "Technology Usage").

```bash
tech-stack-helper.sh reverse React
tech-stack-helper.sh reverse "Next.js" --region US --industry ecommerce --limit 100
tech-stack-helper.sh reverse "React,Tailwind CSS" --operator and
tech-stack-helper.sh reverse "Vue,Angular,Svelte" --operator or
```

**Filters**: `--region`, `--industry`, `--keywords`, `--traffic [low|medium|high|very-high]`, `--limit` (default 50)

**Data sources** (priority order):
1. HTTP Archive (BigQuery) — primary, millions of crawled sites
2. Wappalyzer Public Datasets
3. BuiltWith Trends (free tier, 50 req/day)
4. Chrome UX Report (CrUX)

**HTTP Archive query example**:

```sql
SELECT url, technologies, region, traffic_tier
FROM `httparchive.technologies.2026_02_01`
WHERE EXISTS(SELECT 1 FROM UNNEST(technologies) tech WHERE tech.name = 'React')
  AND region = 'US' AND traffic_tier = 'high'
LIMIT 100
```

**Rate limits**: BigQuery free tier 1TB/month; Wappalyzer API 100 req/day; BuiltWith Trends 50 req/day.

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

# Full scan to markdown
tech-stack-helper.sh lookup https://example.com --format markdown > report.md

# Competitive analysis
tech-stack-helper.sh reverse "Next.js,Vercel,Tailwind CSS" --operator and --limit 200

# Batch lookup
cat urls.txt | xargs -P 4 -I {} tech-stack-helper.sh lookup {} --format json >> results.jsonl

# JSON for scripting
tech-stack-helper.sh lookup https://example.com --format json | jq '.technologies[] | select(.category == "frontend-framework")'
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Provider timeout | `--timeout 60` or `--skip <provider>` |
| Cache stale | `--refresh` or `cache clear <url>` |
| Missing tech | Check `--format json` for `detected_by`; try `--provider unbuilt` for frontend |
| Reverse no results | Try `--region all --traffic all`; check `cache reverse-status` |

## Performance

| Operation | Cache hit | Cache miss |
|-----------|-----------|------------|
| Single-site (all providers) | <100ms | 5–15s |
| Single-site (one provider) | <100ms | 2–5s |
| Reverse lookup | <100ms | 2–10s |

Tips: Use cache aggressively (7-day default is good); `--provider unbuilt` for frontend-only; `xargs -P 4` for batch.

## Future Enhancements

Planned (see TODO.md): historical tracking, vulnerability scanning, performance correlation, cost estimation, migration recommendations. Provider additions: BuiltWith API (paid), Shodan, SecurityHeaders.com, custom fingerprint DB.

## Related Documentation

- **Provider Subagents**: `providers/unbuilt.md`, `providers/crft-lookup.md`, `providers/openexplorer.md`, `providers/wappalyzer.md`
- **Reverse Lookup**: Task t1068 (HTTP Archive integration)
- **Slash Commands**: `scripts/commands/tech-stack.md`
- **Helper Script**: `scripts/tech-stack-helper.sh`
- **Caching**: `reference/memory.md` (SQLite patterns)
