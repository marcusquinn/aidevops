---
mode: subagent
model: sonnet
tools: [bash, read, write]
---

# Wappalyzer OSS Provider

Local/offline technology stack detection using `@ryntab/wappalyzer-node`. Identifies CMS, frameworks, analytics, CDN, JS libraries, UI frameworks (2000+ technologies). No API key or browser required.

**Files:**
- `wappalyzer-helper.sh` — CLI orchestrator with caching and dependency management
- `wappalyzer-detect.mjs` — Node.js wrapper; do **not** invoke directly

## Installation

**Prerequisites:** Node.js 18+, npm, jq

```bash
wappalyzer-helper.sh install   # installs @ryntab/wappalyzer-node + jq
wappalyzer-helper.sh status    # verify
```

## Usage

```bash
# Detect (no cache)
wappalyzer-helper.sh detect https://example.com

# Detect with 7-day cache (recommended for repeated lookups)
wappalyzer-helper.sh detect-cached https://example.com

# Cache management
wappalyzer-helper.sh cache-clear   # clear ~/.aidevops/cache/wappalyzer/

# Help
wappalyzer-helper.sh help
```

Cache files are SHA-256-keyed JSON in `~/.aidevops/cache/wappalyzer/`. Results expire after 7 days.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WAPPALYZER_MAX_WAIT` | `5000` | Max wait time (ms) |
| `WAPPALYZER_TIMEOUT` | `30` | Command timeout (seconds) |

## Output Format

JSON in the common schema — no normalisation needed:

```json
{
  "provider": "wappalyzer",
  "url": "https://example.com",
  "timestamp": "2026-02-16T21:30:00Z",
  "technologies": [
    {
      "name": "React",
      "slug": "react",
      "version": "18.2.0",
      "category": "JavaScript frameworks",
      "confidence": 100,
      "description": "...",
      "website": "https://reactjs.org",
      "source": "wappalyzer"
    }
  ]
}
```

Fields: `slug` (lowercase-hyphenated id), `confidence` (0–100), `version`/`description`/`website` (null if unavailable), `source` always `"wappalyzer"`.

## Integration with tech-stack-helper.sh

Output is already in the common schema — no `jq` normalisation needed. The orchestrator calls:

```bash
wappalyzer-helper.sh detect "$url"          # no cache
wappalyzer-helper.sh detect-cached "$url"   # with cache
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `@ryntab/wappalyzer-node` not found | `wappalyzer-helper.sh install` or `npm install -g @ryntab/wappalyzer-node` |
| Node.js not found | `brew install node` (macOS) or install Node.js 18+ for your platform |
| Detection times out | `WAPPALYZER_TIMEOUT=60 wappalyzer-helper.sh detect https://slow-site.com` |
| Stale cache results | `wappalyzer-helper.sh cache-clear && wappalyzer-helper.sh detect https://example.com` |

**Bulk analysis** — use `detect-cached` with delays:

```bash
while IFS= read -r url; do
  wappalyzer-helper.sh detect-cached "$url" > "results/$(echo "$url" | shasum -a 256 | cut -d' ' -f1).json"
  sleep 2
done < urls.txt
```

## Alternatives

- **Unbuilt.app** (t1064): Specialised in bundler/minifier detection
- **CRFT Lookup** (t1065): Cloudflare Radar tech detection
- **BuiltWith API**: Commercial service (requires API key)

## References

- npm: https://www.npmjs.com/package/@ryntab/wappalyzer-node
- Original repo (archived): https://github.com/AliasIO/wappalyzer
- Technology database: https://github.com/wappalyzer/wappalyzer/tree/master/src/technologies

## Related Tasks

- t1063: Tech stack lookup orchestrator
- t1064: Unbuilt.app provider
- t1065: CRFT Lookup provider
- t1066: BuiltWith provider
- t1067: Wappalyzer provider implementation
