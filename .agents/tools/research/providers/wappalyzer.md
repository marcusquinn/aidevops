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

### Install Wappalyzer CLI

```bash
npm install -g wappalyzer
```

Verify installation:

```bash
wappalyzer --version
```

## Usage

### Basic Detection

```bash
# Analyze a URL and output JSON
wappalyzer https://example.com --format=json

# Pretty-printed output
wappalyzer https://example.com --format=json --pretty

# Increase timeout for slow sites
wappalyzer https://example.com --max-wait=10000
```

### Advanced Options

```bash
# Custom user agent
wappalyzer https://example.com --user-agent="Custom Bot 1.0"

# Recursive crawling (analyze multiple pages)
wappalyzer https://example.com --recursive --max-depth=3 --max-urls=10

# Debug mode
wappalyzer https://example.com --debug

# Probe additional endpoints
wappalyzer https://example.com --probe
```

### Programmatic Usage

```javascript
const Wappalyzer = require('wappalyzer');

const options = {
  debug: false,
  delay: 500,
  headers: {},
  maxDepth: 3,
  maxUrls: 10,
  maxWait: 5000,
  recursive: false,
  probe: true,
  pretty: false,
  userAgent: 'Wappalyzer',
};

const wappalyzer = new Wappalyzer(options);

(async function() {
  try {
    await wappalyzer.init();
    
    const site = await wappalyzer.open('https://example.com');
    const results = await site.analyze();
    
    console.log(JSON.stringify(results, null, 2));
    
    await wappalyzer.destroy();
  } catch (error) {
    console.error(error);
  }
})();
```

## Output Format

Wappalyzer returns a structured JSON object:

```json
{
  "urls": {
    "https://example.com": {
      "status": 200,
      "technologies": [
        {
          "slug": "react",
          "name": "React",
          "description": "React is an open-source JavaScript library for building user interfaces.",
          "confidence": 100,
          "version": "18.2.0",
          "icon": "React.svg",
          "website": "https://reactjs.org",
          "cpe": "cpe:/a:facebook:react",
          "categories": [
            {
              "id": 12,
              "slug": "javascript-frameworks",
              "name": "JavaScript frameworks"
            }
          ]
        },
        {
          "slug": "webpack",
          "name": "Webpack",
          "confidence": 100,
          "version": "5.88.2",
          "categories": [
            {
              "id": 19,
              "slug": "miscellaneous",
              "name": "Miscellaneous"
            }
          ]
        }
      ]
    }
  }
}
```

### Key Fields

- **slug**: Technology identifier (lowercase, hyphenated)
- **name**: Human-readable technology name
- **confidence**: Detection confidence (0-100)
- **version**: Detected version (if available)
- **categories**: Technology categories (framework, CMS, analytics, etc.)
- **description**: Technology description
- **website**: Official website URL
- **cpe**: Common Platform Enumeration identifier (for security scanning)

## Common Schema Mapping

For integration with tech-stack-helper.sh, map Wappalyzer output to the common schema:

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

## Integration with tech-stack-helper.sh

The tech-stack-helper.sh orchestrator calls this provider via:

```bash
# Single-site detection
wappalyzer-detect() {
  local url="$1"
  local output_file="${2:-/dev/stdout}"
  
  # Run Wappalyzer with JSON output
  wappalyzer "$url" --format=json --pretty > "$output_file" 2>/dev/null
  
  return $?
}

# Parse and normalize to common schema
wappalyzer-normalize() {
  local input_file="$1"
  
  jq '{
    provider: "wappalyzer",
    url: (.urls | keys[0]),
    timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    technologies: [
      (.urls | to_entries[0].value.technologies[] | {
        name: .name,
        slug: .slug,
        version: .version // null,
        category: (.categories[0].name // "Unknown"),
        confidence: .confidence,
        source: "wappalyzer"
      })
    ]
  }' "$input_file"
}
```

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

Increase `--max-wait` for slow sites:

```bash
wappalyzer https://slow-site.com --max-wait=15000
```

### Detection Accuracy

- **Probe mode** (`--probe`): Checks additional endpoints like `/robots.txt`, `/sitemap.xml`
- **Recursive mode** (`--recursive`): Analyzes multiple pages for better coverage
- **Confidence threshold**: Filter results by confidence score (e.g., `confidence >= 75`)

### Rate Limiting

For bulk analysis, add delays between requests:

```bash
for url in $(cat urls.txt); do
  wappalyzer "$url" --format=json > "results/${url//\//_}.json"
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
