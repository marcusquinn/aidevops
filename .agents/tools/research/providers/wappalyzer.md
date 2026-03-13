---
mode: subagent
model: sonnet
tools: [bash, read, write]
---

# Wappalyzer OSS Provider

Local/offline technology stack detection using `@ryntab/wappalyzer-node` via `wappalyzer-helper.sh`.

## Overview

Wappalyzer is a technology profiler that identifies software on websites: CMS, frameworks, analytics,
CDN, hosting, JavaScript libraries, UI frameworks, and more. This provider uses the
`@ryntab/wappalyzer-node` npm package (a maintained fork of the original Wappalyzer engine) with a
custom shell helper and Node.js wrapper for local, offline detection.

**Strengths**:

- Comprehensive technology database (2000+ technologies)
- Local/offline detection (no API dependencies)
- 7-day result cache for repeated lookups
- JSON output in common schema for `tech-stack-helper.sh` integration

**Use cases**:

- Tech stack audits
- Competitor analysis
- Security assessments
- Migration planning

## Implementation

The provider consists of three files:

| File | Purpose |
|------|---------|
| `.agents/scripts/wappalyzer-helper.sh` | CLI entry point — commands, caching, dependency management |
| `.agents/scripts/wappalyzer-detect.mjs` | Node.js ES module — calls `@ryntab/wappalyzer-node`, transforms output to common schema |
| `.agents/scripts/package.json` | npm manifest declaring `@ryntab/wappalyzer-node` dependency |

## Installation

### Prerequisites

- Node.js 18+
- npm

### Install via helper script

```bash
.agents/scripts/wappalyzer-helper.sh install
```

This installs `@ryntab/wappalyzer-node` globally via npm. The helper script also requires `jq`
and will attempt to install it via Homebrew on macOS. On other systems, install `jq` manually
before running this command.

### Verify installation

```bash
.agents/scripts/wappalyzer-helper.sh status
```

## Usage

All interaction goes through `wappalyzer-helper.sh`:

```bash
# Detect technologies for a URL (no cache)
.agents/scripts/wappalyzer-helper.sh detect https://example.com

# Detect with 7-day cache
.agents/scripts/wappalyzer-helper.sh detect-cached https://example.com

# Install dependencies
.agents/scripts/wappalyzer-helper.sh install

# Show installation and cache status
.agents/scripts/wappalyzer-helper.sh status

# Clear cached results
.agents/scripts/wappalyzer-helper.sh cache-clear

# Show help
.agents/scripts/wappalyzer-helper.sh help
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WAPPALYZER_MAX_WAIT` | `5000` | Max wait time in ms |
| `WAPPALYZER_TIMEOUT` | `30` | Command timeout in seconds |

## Output Format

All commands output JSON in the common schema:

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
    }
  ]
}
```

### Key Fields

- **slug**: Technology identifier (lowercase, hyphenated)
- **name**: Human-readable technology name
- **confidence**: Detection confidence (0–100)
- **version**: Detected version (if available, otherwise `null`)
- **category**: Primary technology category (from `@ryntab/wappalyzer-node`)
- **description**: Technology description (if available, otherwise `null`)
- **website**: Official website URL (if available, otherwise `null`)
- **source**: Always `"wappalyzer"`

## Integration with tech-stack-helper.sh

The `tech-stack-helper.sh` orchestrator calls this provider via the helper script:

```bash
# Single-site detection (no cache)
.agents/scripts/wappalyzer-helper.sh detect "$url"

# Cached detection (recommended for repeated lookups)
.agents/scripts/wappalyzer-helper.sh detect-cached "$url"
```

Output is already in the common schema — no normalization step required.

## Caching

Results are cached in `~/.aidevops/cache/wappalyzer/` as SHA-256-keyed JSON files.
Cache TTL is 7 days. Use `detect-cached` for repeated lookups; use `detect` to bypass the cache.

```bash
# Clear all cached results
.agents/scripts/wappalyzer-helper.sh cache-clear
```

## Troubleshooting

### `@ryntab/wappalyzer-node` not found

Run the install command:

```bash
.agents/scripts/wappalyzer-helper.sh install
```

Or install manually:

```bash
npm install -g @ryntab/wappalyzer-node
```

### Node.js not found

Install Node.js 18+:

```bash
# macOS
brew install node

# Linux (Debian/Ubuntu)
# The 'nodejs' package in default repositories is often outdated.
# Please follow official instructions to install Node.js 18+.
# See: https://nodejs.org/en/download/package-manager
```

### Timeout errors

Increase `WAPPALYZER_TIMEOUT` for slow sites:

```bash
WAPPALYZER_TIMEOUT=60 .agents/scripts/wappalyzer-helper.sh detect https://slow-site.com
```

### ES module import errors

`wappalyzer-detect.mjs` uses ES module syntax (`import`). Ensure Node.js 18+ is installed.
The helper sets `NODE_PATH` to the global npm modules directory automatically.

## Alternatives

If this provider doesn't meet your needs:

- **Unbuilt.app** (t1064): Specialized in bundler/minifier detection
- **CRFT Lookup** (t1065): Cloudflare Radar tech detection
- **BuiltWith API** (t1066): Commercial service (requires API key)

## References

- **npm package**: https://www.npmjs.com/package/@ryntab/wappalyzer-node
- **Original Wappalyzer repo** (archived): https://github.com/wappalyzer/wappalyzer

## Related Tasks

- t1063: Tech stack lookup orchestrator (`tech-stack-helper.sh`)
- t1064: Unbuilt.app provider
- t1065: CRFT Lookup provider
- t1066: BuiltWith provider
- t1067: This provider (Wappalyzer OSS)
