---
mode: subagent
model: sonnet
tools: [bash, read, write]
---

# Wappalyzer OSS Provider

Local/offline technology stack detection using the `@ryntab/wappalyzer-node` package with a custom shell helper.

## Overview

Wappalyzer is a technology profiler that identifies software on websites: CMS, frameworks, analytics, CDN, hosting, JavaScript libraries, UI frameworks, and more. The core detection engine was open-source before acquisition and remains available through maintained forks and npm packages.

This provider is implemented as two files:

- **`wappalyzer-helper.sh`** — Shell orchestrator with CLI commands, caching, and dependency management
- **`wappalyzer-detect.mjs`** — Node.js wrapper that calls `@ryntab/wappalyzer-node` and normalises output to the common schema

**Strengths**:

- Comprehensive technology database (2000+ technologies)
- Local/offline detection (no API dependencies)
- HTTP fetch-based detection (no browser/Chromium required)
- JSON output in common schema (no post-processing needed)
- 7-day result cache keyed by URL SHA-256

**Use cases**:

- Tech stack audits
- Competitor analysis
- Security assessments
- Migration planning

## Installation

### Prerequisites

- Node.js 18+ and npm
- jq (for JSON parsing)

### Install Dependencies

Use the helper script to install all dependencies in one step:

```bash
wappalyzer-helper.sh install
```

This installs:

- `@ryntab/wappalyzer-node` globally via npm
- `jq` via Homebrew (macOS) if not already present

To verify the installation:

```bash
wappalyzer-helper.sh status
```

## Usage

All operations go through `wappalyzer-helper.sh`. Do **not** invoke `wappalyzer-detect.mjs` directly.

### Basic Detection

```bash
# Detect technologies for a URL (no cache)
wappalyzer-helper.sh detect https://example.com

# Detect with 7-day cache (recommended for repeated lookups)
wappalyzer-helper.sh detect-cached https://example.com
```

### Cache Management

```bash
# Clear all cached results
wappalyzer-helper.sh cache-clear
```

Cache files are stored in `~/.aidevops/cache/wappalyzer/` as SHA-256-keyed JSON files. Results expire after 7 days.

### Status and Help

```bash
# Show installation and cache status
wappalyzer-helper.sh status

# Show all available commands
wappalyzer-helper.sh help
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WAPPALYZER_MAX_WAIT` | `5000` | Max wait time in milliseconds |
| `WAPPALYZER_TIMEOUT` | `30` | Command timeout in seconds |

## Output Format

The helper outputs JSON directly in the common schema — no normalisation step is required:

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
      "description": "React is an open-source JavaScript library for building user interfaces.",
      "website": "https://reactjs.org",
      "source": "wappalyzer"
    },
    {
      "name": "Webpack",
      "slug": "webpack",
      "version": "5.88.2",
      "category": "Miscellaneous",
      "confidence": 100,
      "description": null,
      "website": null,
      "source": "wappalyzer"
    }
  ]
}
```

### Key Fields

- **slug**: Technology identifier (lowercase, hyphenated)
- **name**: Human-readable technology name
- **confidence**: Detection confidence (0–100)
- **version**: Detected version (if available, otherwise `null`)
- **category**: Primary technology category (first category from detection results)
- **description**: Technology description (if available, otherwise `null`)
- **website**: Official website URL (if available, otherwise `null`)
- **source**: Always `"wappalyzer"`

## Integration with tech-stack-helper.sh

The tech-stack-helper.sh orchestrator calls this provider via the shell helper:

```bash
# Single-site detection (no cache)
wappalyzer-helper.sh detect "$url"

# Single-site detection with cache
wappalyzer-helper.sh detect-cached "$url"
```

Output is already in the common schema — no `jq` normalisation is needed.

## How It Works

Detection uses HTTP fetch (not a headless browser). The Node.js wrapper (`wappalyzer-detect.mjs`) calls:

```javascript
import { scan } from '@ryntab/wappalyzer-node';

const results = await scan(url, { target: 'fetch' });
```

The shell helper (`wappalyzer-helper.sh`) sets `NODE_PATH` to the global npm modules directory so the wrapper can resolve `@ryntab/wappalyzer-node` regardless of the working directory.

## Troubleshooting

### `@ryntab/wappalyzer-node` Not Found

Run the install command:

```bash
wappalyzer-helper.sh install
```

Or install manually:

```bash
npm install -g @ryntab/wappalyzer-node
```

### Node.js Not Found

Install Node.js 18+:

```bash
# macOS
brew install node

# Linux (Debian/Ubuntu)
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### Detection Fails or Times Out

Increase the timeout via environment variable:

```bash
WAPPALYZER_TIMEOUT=60 wappalyzer-helper.sh detect https://slow-site.com
```

### Stale Cache Results

Clear the cache and re-detect:

```bash
wappalyzer-helper.sh cache-clear
wappalyzer-helper.sh detect https://example.com
```

### Bulk Analysis

For bulk analysis, use `detect-cached` to avoid redundant requests and add delays between calls:

```bash
while IFS= read -r url; do
  wappalyzer-helper.sh detect-cached "$url" > "results/$(echo "$url" | shasum -a 256 | cut -d' ' -f1).json"
  sleep 2
done < urls.txt
```

## Alternatives

If Wappalyzer doesn't meet your needs:

- **Unbuilt.app** (t1064): Specialised in bundler/minifier detection
- **CRFT Lookup** (t1065): Cloudflare Radar tech detection
- **BuiltWith API**: Commercial service (requires API key)

## References

- **npm package**: https://www.npmjs.com/package/@ryntab/wappalyzer-node
- **Original Wappalyzer repo** (archived): https://github.com/AliasIO/wappalyzer
- **Technology database**: https://github.com/wappalyzer/wappalyzer/tree/master/src/technologies

## Related Tasks

- t1063: Tech stack lookup orchestrator
- t1064: Unbuilt.app provider
- t1065: CRFT Lookup provider
- t1066: BuiltWith provider
- t1067: Wappalyzer provider implementation
