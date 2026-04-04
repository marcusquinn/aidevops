---
mode: subagent
model: sonnet
tools: [bash, read, write]
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Wappalyzer OSS Provider

Local/offline technology stack detection via `@ryntab/wappalyzer-node`. Identifies 2000+ technologies (CMS, frameworks, analytics, CDN, JS libraries, UI frameworks). No API key or browser required.

**Scripts:** `wappalyzer-helper.sh` (CLI orchestrator, caching) · `wappalyzer-detect.mjs` (Node.js wrapper — do not invoke directly)

## Installation

**Prerequisites:** Node.js 18+, npm, jq

```bash
wappalyzer-helper.sh install   # installs @ryntab/wappalyzer-node + jq
wappalyzer-helper.sh status    # verify
```

## Usage

```bash
wappalyzer-helper.sh detect https://example.com          # no cache
wappalyzer-helper.sh detect-cached https://example.com   # 7-day cache (recommended)
wappalyzer-helper.sh cache-clear                         # clear ~/.aidevops/cache/wappalyzer/
wappalyzer-helper.sh help
```

Cache files: SHA-256-keyed JSON in `~/.aidevops/cache/wappalyzer/`, expire after 7 days.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WAPPALYZER_MAX_WAIT` | `5000` | Max wait time (ms) |
| `WAPPALYZER_TIMEOUT` | `30` | Command timeout (seconds) |

## Output Format

Common schema — no `jq` normalisation needed for `tech-stack-helper.sh`:

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

`slug`: lowercase-hyphenated id. `confidence`: 0–100. `version`/`description`/`website`: null if unavailable. `source`: always `"wappalyzer"`.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `@ryntab/wappalyzer-node` not found | `wappalyzer-helper.sh install` or `npm install -g @ryntab/wappalyzer-node` |
| Node.js not found | `brew install node` (macOS) or install Node.js 18+ |
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
