---
description: Browser QA — Playwright-based visual testing for milestone validation, detecting layout bugs, broken links, missing content, and console errors
mode: subagent
model: sonnet  # structured checking, not complex reasoning
tools:
  read: true
  write: false
  edit: false
  bash: true
  task: true
---

# Browser QA

<!-- AI-CONTEXT-START -->

**Purpose**: Visual QA for milestone validation — verify pages render, links work, no JS errors.

| File | Purpose |
|------|---------|
| `scripts/browser-qa-worker.sh` | Shell wrapper with CLI, mission integration |
| `scripts/browser-qa/browser-qa.mjs` | Playwright engine (Node.js) |
| `scripts/milestone-validation-worker.sh` | Parent validation worker |
| `workflows/milestone-validation.md` | Validation workflow docs |
| `tools/browser/browser-automation.md` | Browser tool selection guide |

<!-- AI-CONTEXT-END -->

## When to Use

| Flag | What it does | When to use |
|------|-------------|-------------|
| `--browser-tests` | Runs the project's own Playwright test suite | Project has `playwright.config.{ts,js}` |
| `--browser-qa` | Runs generic visual QA (screenshots, links, errors) | Any UI project, especially POC-mode missions without a test suite |

Both flags can be combined. Use `--browser-qa` when there's no project test suite or you need a quick smoke test after milestone completion.

## What It Checks

| Check | What it detects | Severity |
|-------|----------------|----------|
| **HTTP status** | 4xx/5xx responses | Fail |
| **Empty page** | Body text < 10 characters | Fail |
| **Error states** | "Application error", "Internal server error", hydration failures | Fail |
| **Console errors** | JS exceptions, uncaught errors | Fail |
| **Network errors** | Failed fetch/XHR requests | Fail |
| **Broken links** | `<a>` hrefs returning 4xx/5xx or timing out | Fail |
| **Screenshot** | Full-page screenshot for human review | Info |
| **ARIA snapshot** | Structural accessibility tree | Info |

Aggregate report: total pages/passed/failed, broken links, console errors, screenshot paths, JSON at `{output-dir}/qa-report.json`.

## Usage

```bash
# Basic — visit homepage, check links, screenshot
browser-qa-worker.sh --url http://localhost:3000

# Multiple pages
browser-qa-worker.sh --url http://localhost:3000 \
  --flows '["/", "/about", "/login", "/dashboard"]'

# Mission-aware — extract flows from acceptance criteria
browser-qa-worker.sh --url http://localhost:3000 \
  --mission-file ~/Git/myproject/todo/missions/m001/mission.md \
  --milestone 2

# Other flags: --output-dir <path>, --format json, --no-check-links

# From milestone validation (both flags can be combined)
milestone-validation-worker.sh mission.md 2 \
  --browser-tests --browser-qa --browser-url http://localhost:3000 \
  --browser-qa-flows '["/", "/about", "/api/health"]'  # optional: override flows
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All QA checks passed |
| `1` | QA checks failed (issues found) |
| `2` | Configuration error (missing args, Playwright not installed) |

## Flow Definitions

Flows specify which pages to visit. Two formats:

```json
// Simple list (relative URLs resolved against base URL)
["/", "/about", "/contact", "/login"]

// Named flows
[{"url": "/", "name": "homepage"}, {"url": "/login", "name": "login-page"}]
```

When `--mission-file` and `--milestone` are provided, flows are extracted automatically from the milestone's acceptance criteria (URL-like patterns: `/about`, `/api/health`).

## Output

Screenshots saved to `{output-dir}/{hostname}_{path}.png` (error variant: `{hostname}_{path}-error.png`).

JSON report at `{output-dir}/qa-report.json`:

```json
{
  "baseUrl": "http://localhost:3000",
  "timestamp": "2026-02-28T12:00:00.000Z",
  "viewport": "1280x720",
  "pages": [{"url": "...", "status": 200, "passed": true, "failures": [], "consoleErrors": [], "linkResults": [...]}],
  "passed": true
}
```

## Prerequisites

- **Node.js** v18+
- **Playwright**: `npm install playwright && npx playwright install` (Chromium by default)

## Related

| Tool/Doc | Purpose |
|----------|---------|
| `scripts/milestone-validation-worker.sh` | Parent validation worker |
| `workflows/milestone-validation.md` | Validation workflow |
| `workflows/mission-orchestrator.md` | Mission orchestrator |
| `tools/browser/browser-automation.md` | Browser tool selection guide |
| `tools/browser/playwright.md` | Playwright reference |
| `playwright-contrast.mjs` | WCAG contrast analysis |
| `accessibility-audit-helper.sh` | Full accessibility audit (WCAG compliance) |
| `pagespeed` | Performance / Core Web Vitals |
