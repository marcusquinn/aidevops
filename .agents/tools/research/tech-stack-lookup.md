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

- **CLI**: `tech-stack-helper.sh [lookup|reverse|report|cache]`
- **Cache**: `~/.aidevops/.agent-workspace/tech-stacks/cache.db` (SQLite, 7-day TTL)
- **Slash commands**: `/tech-stack <url>` · `/tech-stack reverse <tech> [--region X] [--industry Y]` · aliases: `/tech`, `/stack`
- **Output**: terminal table (default), `--format json`, `--format markdown`

**Modes**: Single-site lookup (detect full tech stack of a URL) · Reverse lookup (find sites using specific tech)

**Providers** (parallel execution, read subagent on demand):

| Provider | Subagent | Strengths |
|----------|----------|-----------|
| Unbuilt.app | `providers/unbuilt.md` | Frontend/JS specialist, CLI available |
| CRFT Lookup | `providers/crft-lookup.md` | 2500+ fingerprints, Lighthouse scores |
| OpenExplorer | `providers/openexplorer.md` | Open-source, community-driven |
| Wappalyzer OSS | `providers/wappalyzer.md` | Self-hosted, offline capable |

<!-- AI-CONTEXT-END -->

## Single-Site Lookup

```bash
tech-stack-helper.sh lookup https://example.com
tech-stack-helper.sh lookup https://example.com --provider unbuilt  # fastest, frontend-only
cat urls.txt | xargs -P 4 -I {} tech-stack-helper.sh lookup {} --format json >> results.jsonl
```

Options: `--format json|markdown`, `--provider <name>`, `--skip <provider>`, `--timeout <secs>`, `--refresh` (bypass cache), `--ttl <secs>`.

**Detection categories**: Frontend frameworks, backend, bundlers, state management, CMS, analytics, CDN, hosting, monitoring, performance.

**Workflow**: Check cache → dispatch all providers in parallel (30s timeout each) → merge + deduplicate → cache → return.

**Merge rules**: Same tech from multiple providers → keep highest confidence. Version conflicts → keep most specific (`18.2.0` over `18.x`). 2+ providers agreeing → high confidence.

## Reverse Lookup

Find websites using specific technologies (replicates BuiltWith "Technology Usage").

```bash
tech-stack-helper.sh reverse React
tech-stack-helper.sh reverse "Next.js" --region US --industry ecommerce --limit 100
tech-stack-helper.sh reverse "React,Tailwind CSS" --operator and
```

**Filters**: `--region`, `--industry`, `--keywords`, `--traffic [low|medium|high|very-high]`, `--limit` (default 50), `--operator [and|or]`

**Data sources** (priority): HTTP Archive/BigQuery (primary) → Wappalyzer Public Datasets → BuiltWith Trends (50 req/day free) → Chrome UX Report (CrUX).

**Rate limits**: BigQuery free tier 1TB/month; Wappalyzer API 100 req/day; BuiltWith Trends 50 req/day.

## Caching

```bash
tech-stack-helper.sh cache status          # view cache state
tech-stack-helper.sh cache clear <url>     # or --all
```

Cache hit: fresh → return immediately; expired → refresh in background, return stale; miss → fetch all providers. Reverse lookup cache: 30-day TTL (HTTP Archive updates monthly). `cache reverse-status` / `cache clear-reverse`.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Provider timeout | `--timeout 60` or `--skip <provider>` |
| Cache stale | `--refresh` or `cache clear <url>` |
| Missing tech | Check `--format json` for `detected_by`; try `--provider unbuilt` for frontend |
| Reverse no results | Try `--region all --traffic all`; check `cache reverse-status` |

## Related

- **Slash command**: `scripts/commands/tech-stack.md`
- **Helper script**: `scripts/tech-stack-helper.sh`
- **Reverse lookup**: task t1068 (HTTP Archive integration)
- **Caching patterns**: `reference/memory.md`
