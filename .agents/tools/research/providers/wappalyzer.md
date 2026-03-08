---
mode: subagent
model: sonnet
tools: [bash, read, write]
---

# Wappalyzer OSS Provider

Local/offline technology stack detection using Wappalyzer's open-source detection engine.

## Overview

Wappalyzer is a technology profiler that identifies software on websites: CMS, frameworks, analytics, CDN, hosting, JavaScript libraries, UI frameworks, and more. The core detection engine was open-source before acquisition and remains available through maintained forks and npm packages.

**Strengths**:
- Comprehensive technology database (2000+ technologies)
- Local/offline detection (no API dependencies)
- Headless browser support
- JSON output for programmatic use
- Active maintenance via official npm package

**Use cases**:
- Tech stack audits
- Competitor analysis
- Security assessments
- Migration planning

## Installation

### Prerequisites

- Node.js 18+ and npm
- Chrome/Chromium (for headless browser detection)

### Install via Helper Script

The framework uses `wappalyzer-helper.sh` with `@ryntab/wappalyzer-node` (a maintained fork):

```bash
wappalyzer-helper.sh install
```

This installs the dependencies required by the Node.js wrapper (`wappalyzer-detect.mjs`).

Verify installation:

```bash
wappalyzer-helper.sh detect https://example.com
```

## Usage

### Basic Detection

```bash
# Analyze a URL via helper script (recommended)
wappalyzer-helper.sh detect https://example.com

# Output JSON to file (use shell redirection)
wappalyzer-helper.sh detect https://example.com > results.json

# Use cached results (7-day TTL)
wappalyzer-helper.sh detect-cached https://example.com
```

### Programmatic Usage

The wrapper script `wappalyzer-detect.mjs` (in `.agents/scripts/`) uses `@ryntab/wappalyzer-node`:

```javascript
import { scan } from '@ryntab/wappalyzer-node';

const url = process.argv[2] || 'https://example.com';
const results = await scan(url, { target: 'fetch' });
console.log(JSON.stringify(results, null, 2));
```

For direct Node.js integration, use the wrapper:

```bash
node .agents/scripts/wappalyzer-detect.mjs https://example.com
```

## Output Format

When using `wappalyzer-helper.sh detect`, the output is a normalized JSON object in the common schema format. The wrapper (`wappalyzer-detect.mjs`) transforms the raw library output automatically.

### Common Schema (Default Output)

This is the format returned by `wappalyzer-helper.sh detect` and `wappalyzer-detect.mjs`:

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
      "source": "wappalyzer"
    }
  ]
}
```

### Key Fields

- **slug**: Technology identifier (lowercase, hyphenated)
- **name**: Human-readable technology name
- **confidence**: Detection confidence (0-100)
- **version**: Detected version (if available)
- **category**: Technology category (framework, CMS, analytics, etc.)
- **source**: Always `"wappalyzer"` for this provider

### Raw Library Output (Advanced Reference)

The underlying `@ryntab/wappalyzer-node` library returns a different nested structure with a `urls` object keyed by URL. You will only see this format if you call the library directly (not via the helper script or wrapper). The wrapper `wappalyzer-detect.mjs` transforms this raw format into the common schema above.

Raw output includes additional fields not present in the common schema: `description`, `website`, `icon`, `cpe` (Common Platform Enumeration for security scanning), and nested `categories` with `id`/`slug`/`name`. See the `@ryntab/wappalyzer-node` package documentation for the full raw schema.

## Integration with tech-stack-helper.sh

The tech-stack-helper.sh orchestrator calls this provider via `wappalyzer-helper.sh`:

```bash
# Single-site detection (uses wappalyzer-detect.mjs internally)
wappalyzer-helper.sh detect https://example.com

# Save normalized output to file (use shell redirection)
wappalyzer-helper.sh detect https://example.com > results.json
```

The helper script handles detection, normalization, and error handling internally. See `.agents/scripts/wappalyzer-helper.sh` for the full implementation.

## Troubleshooting

### Chrome/Chromium Not Found

Wappalyzer requires Chrome/Chromium for headless detection. Install via:

```bash
# macOS
brew install --cask google-chrome

# Linux (Debian/Ubuntu)
sudo apt-get install chromium-browser

# Set custom Chrome path if needed
export CHROME_BIN=/path/to/chrome
```

### Timeout Errors

If detection times out on slow sites, the wrapper script has built-in timeout handling. For manual runs:

```bash
# The helper handles timeouts internally
wappalyzer-helper.sh detect https://slow-site.com
```

### Detection Accuracy

- The `@ryntab/wappalyzer-node` fork analyzes the provided URL and optionally uses Puppeteer-based page loading to detect assets the page itself triggers
- Filter results by confidence score (e.g., `confidence >= 75`) in post-processing
- Multiple page analysis improves coverage

### Rate Limiting

For bulk analysis, add delays between requests:

```bash
for url in $(cat urls.txt); do
  wappalyzer-helper.sh detect "$url" > "results/$(echo -n "$url" | shasum -a 256 | cut -d' ' -f1).json"
  sleep 2
done
```

## Alternatives

If Wappalyzer doesn't meet your needs:

- **Unbuilt.app** (t1064): Specialized in bundler/minifier detection
- **CRFT Lookup** (t1065): Cloudflare Radar tech detection
- **Webtech**: Alternative CLI using Wappalyzer rules
- **BuiltWith API**: Commercial service (requires API key)

## References

- **Official npm package**: https://www.npmjs.com/package/wappalyzer
- **GitHub repository**: https://github.com/wappalyzer/wappalyzer
- **Technology database**: https://github.com/wappalyzer/wappalyzer/tree/master/src/technologies
- **Original archived repo**: https://github.com/AliasIO/wappalyzer (historical reference)

## Related Tasks

- t1063: Tech stack lookup orchestrator
- t1064: Unbuilt.app provider
- t1065: CRFT Lookup provider
- t1066: BuiltWith provider
