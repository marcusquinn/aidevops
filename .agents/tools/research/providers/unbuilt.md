---
description: Unbuilt.app provider — real-time frontend technology detection via CLI
mode: subagent
model: sonnet
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
---

# Unbuilt.app Provider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Detect frontend technologies on live websites via real-time JS analysis
- **CLI**: `@unbuilt/cli` (npm), usage: `unbuilt <url>`
- **Source**: [github.com/yavorsky/unbuilt.app](https://github.com/yavorsky/unbuilt.app) (MIT)
- **Strengths**: Real-time code analysis of bundled/minified JS (not static signatures)
- **Prerequisite**: Node.js 16+, Playwright Chromium (`npx playwright install chromium`)
- **Helper**: `tech-stack-helper.sh unbuilt <url> [--json]`

## What It Detects

| Category | Examples |
|----------|----------|
| Bundlers | Webpack, Vite, Rollup, Parcel, esbuild, Turbopack |
| UI Libraries | React, Vue, Angular, Svelte |
| Frameworks | Next.js, Nuxt.js, Remix, VitePress, Storybook, SvelteKit |
| Minifiers | Terser, UglifyJS |
| Styling Processors | Sass, Less, PostCSS |
| Module Systems | CommonJS, ES Modules, AMD |
| Styling Libraries | Tailwind CSS, Material UI, Chakra UI, shadcn/ui, Lucide |
| State Management | Redux, MobX, Zustand |
| HTTP Clients | Axios, Fetch, SuperAgent |
| Routers | React Router, Vue Router, Next.js internal router |
| Translation (i18n) | i18next, react-intl |
| Date Libraries | Moment.js, date-fns, Luxon |
| Analytics | Google Analytics, Mixpanel, Umami, Microsoft Clarity |
| Transpilers | Babel, SWC, TypeScript |
| Monitoring | Sentry, Datadog, Rollbar, New Relic, OpenTelemetry, Vercel Speed Insights |
| Platforms | Wix, Weebly, Webflow, Squarespace, Shopify |

## CLI Installation

```bash
npm install -g @unbuilt/cli
npx playwright install chromium
```

## CLI Usage

```bash
# Basic analysis (human-readable output)
unbuilt https://example.com

# JSON output (machine-readable, for integration)
unbuilt https://example.com --json

# Remote analysis (uses unbuilt.app server, no local Playwright needed)
unbuilt https://example.com --remote --json

# With authenticated session (uses local Chrome profile)
unbuilt https://example.com --session

# Custom timeout (default 120s)
unbuilt https://example.com --timeout 60

# Batch analysis from CSV
unbuilt batch urls.csv --concurrent 4 --json --output results.json
```

## CLI Options

| Flag | Description |
|------|-------------|
| `-j, --json` | Output results in JSON format |
| `-r, --remote` | Run analysis on unbuilt.app server (no local browser needed) |
| `-n, --async` | Async remote execution (returns job ID) |
| `--refresh` | Force fresh analysis (bypass cache) |
| `-t, --timeout <s>` | Max wait time in seconds (default: 120) |
| `--session` | Use local Chrome profile for authenticated analysis |

## Integration Pattern

The `tech-stack-helper.sh` script wraps the CLI for the aidevops framework:

```bash
# Analyze a single URL
tech-stack-helper.sh unbuilt https://example.com

# JSON output for programmatic use
tech-stack-helper.sh unbuilt https://example.com --json

# Auto-install CLI if missing
tech-stack-helper.sh install unbuilt
```

## Output Schema (JSON mode)

The `--json` flag returns structured results grouped by detection category.
Each detected technology includes the technology name, category, and evidence.

Example structure:

```json
{
  "url": "https://example.com",
  "technologies": {
    "bundlers": ["Webpack"],
    "uiLibraries": ["React"],
    "frameworks": ["Next.js"],
    "styling": ["Tailwind CSS"],
    "stateManagement": ["Redux"],
    "monitoring": ["Sentry"],
    "analytics": ["Google Analytics"]
  }
}
```

## Common Schema Mapping

The helper normalises Unbuilt output into a common tech-stack schema:

| Common Field | Unbuilt Category |
|-------------|-----------------|
| `bundler` | bundlers |
| `ui_library` | uiLibraries |
| `framework` | frameworks |
| `css_framework` | styling / stylingLibraries |
| `state_management` | stateManagement |
| `http_client` | httpClients |
| `router` | routers |
| `i18n` | translationLibraries |
| `date_library` | dateLibraries |
| `analytics` | analytics |
| `monitoring` | monitoring |
| `platform` | platforms |
| `minifier` | minifiers |
| `transpiler` | transpilers |
| `module_system` | moduleSystems |

## Comparison with Alternatives

| Feature | Unbuilt | Wappalyzer | BuiltWith |
|---------|---------|------------|-----------|
| Detection method | Real-time JS execution | Static signatures | Crawl + signatures |
| Open source | MIT | Partially | No |
| Cost | Free | Freemium | Paid |
| Modern tech focus | Excellent | Good | Good |
| Local CLI | Yes | Browser ext only | No |
| Evidence-based | Yes (code proof) | No | No |

## Limitations

- Requires Playwright Chromium for local analysis (or use `--remote`)
- Beta status: detection patterns are actively improving
- Analysis takes 5-30 seconds per URL depending on site complexity
- Some heavily obfuscated sites may yield incomplete results
- Version detection is not yet available (planned feature)

<!-- AI-CONTEXT-END -->
