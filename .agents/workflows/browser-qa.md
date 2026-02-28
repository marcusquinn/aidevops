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

## Quick Reference

- **Purpose**: Visual QA for milestone validation — verify that an app renders correctly, links work, and key flows are navigable
- **Script**: `scripts/browser-qa-worker.sh` (shell wrapper) + `scripts/browser-qa/browser-qa.mjs` (Playwright engine)
- **Invoked by**: `milestone-validation-worker.sh --browser-qa` or standalone
- **Output**: Pass/fail report with screenshots, broken link list, console errors

**Key files**:

| File | Purpose |
|------|---------|
| `scripts/browser-qa-worker.sh` | Shell wrapper with CLI, mission integration |
| `scripts/browser-qa/browser-qa.mjs` | Playwright engine (Node.js) |
| `scripts/milestone-validation-worker.sh` | Parent validation worker |
| `workflows/milestone-validation.md` | Validation workflow docs |
| `tools/browser/browser-automation.md` | Browser tool selection guide |

<!-- AI-CONTEXT-END -->

## When to Use

Browser QA complements the existing `--browser-tests` flag in milestone validation:

| Flag | What it does | When to use |
|------|-------------|-------------|
| `--browser-tests` | Runs the project's own Playwright test suite | Project has `playwright.config.{ts,js}` |
| `--browser-qa` | Runs generic visual QA (screenshots, links, errors) | Any UI project, especially POC-mode missions without a test suite |

Use `--browser-qa` when:

- The project has no Playwright test suite (common in POC mode)
- You want a quick visual smoke test after milestone completion
- You need to verify that pages render, links work, and no JS errors occur
- The mission has acceptance criteria that reference specific pages/flows

## What It Checks

### Per-Page Checks

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

### Aggregate Report

- Total pages visited, passed, failed
- Total broken links across all pages
- Total console errors across all pages
- Screenshot paths for each page
- JSON report at `{output-dir}/qa-report.json`

## Usage

### Standalone

```bash
# Basic — visit homepage, check links, screenshot
browser-qa-worker.sh --url http://localhost:3000

# Multiple pages
browser-qa-worker.sh --url http://localhost:3000 \
  --flows '["/", "/about", "/login", "/dashboard"]'

# Custom output directory
browser-qa-worker.sh --url http://localhost:8080 \
  --output-dir ~/Git/myproject/todo/missions/m001/assets/qa

# JSON output for programmatic consumption
browser-qa-worker.sh --url http://localhost:3000 --format json

# Skip link checking (faster)
browser-qa-worker.sh --url http://localhost:3000 --no-check-links

# Mission-aware — extract flows from acceptance criteria
browser-qa-worker.sh --url http://localhost:3000 \
  --mission-file ~/Git/myproject/todo/missions/m001/mission.md \
  --milestone 2
```

### From Milestone Validation

```bash
# The milestone validation worker delegates to browser-qa-worker.sh
milestone-validation-worker.sh mission.md 2 \
  --browser-qa --browser-url http://localhost:3000

# With custom flows
milestone-validation-worker.sh mission.md 2 \
  --browser-qa --browser-url http://localhost:3000 \
  --browser-qa-flows '["/", "/about", "/api/health"]'
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All QA checks passed |
| `1` | QA checks failed (issues found) |
| `2` | Configuration error (missing args, Playwright not installed) |

## Flow Definitions

Flows define which pages to visit. They can be specified as:

### Simple URL list

```json
["/", "/about", "/contact", "/login"]
```

Relative URLs are resolved against the base URL.

### Named flows with metadata

```json
[
  {"url": "/", "name": "homepage"},
  {"url": "/login", "name": "login-page"},
  {"url": "/dashboard", "name": "dashboard"}
]
```

### From mission file

When `--mission-file` and `--milestone` are provided, the worker extracts route patterns from the milestone's acceptance criteria section. It looks for URL-like patterns (`/about`, `/dashboard`, `/api/health`) in the milestone text.

## Integration with Milestone Validation

The milestone validation worker (`scripts/milestone-validation-worker.sh`) supports two browser-related flags:

```text
--browser-tests     Run project's Playwright test suite (existing)
--browser-qa        Run generic visual QA via browser-qa-worker.sh (new)
```

Both can be used together:

```bash
milestone-validation-worker.sh mission.md 1 \
  --browser-tests --browser-qa --browser-url http://localhost:3000
```

The validation worker records browser QA results as a separate check in the validation report.

## Output

### Screenshots

Full-page screenshots are saved to `{output-dir}/{hostname}_{path}.png`. On navigation errors, an error screenshot is captured as `{hostname}_{path}-error.png`.

### JSON Report

A structured report is written to `{output-dir}/qa-report.json`:

```json
{
  "baseUrl": "http://localhost:3000",
  "timestamp": "2026-02-28T12:00:00.000Z",
  "viewport": "1280x720",
  "outputDir": "/tmp/browser-qa-20260228-120000",
  "pages": [
    {
      "url": "http://localhost:3000/",
      "name": "homepage",
      "status": 200,
      "title": "My App",
      "screenshot": "/tmp/browser-qa-20260228-120000/localhost_3000_index.png",
      "isEmpty": false,
      "hasErrorState": false,
      "consoleErrors": [],
      "networkErrors": [],
      "linkResults": [
        {"href": "http://localhost:3000/about", "text": "About", "status": 200}
      ],
      "loadTimeMs": 1234,
      "passed": true,
      "failures": []
    }
  ],
  "passed": true
}
```

## Prerequisites

- **Node.js** (v18+)
- **Playwright** (`npm install playwright && npx playwright install`)
- Playwright browsers installed (Chromium is used by default)

## Relationship to Other Browser Tools

| Tool | Purpose | When to use |
|------|---------|-------------|
| **browser-qa-worker.sh** | Generic visual QA (this tool) | Milestone validation, smoke testing |
| **playwright-contrast.mjs** | WCAG contrast analysis | Accessibility audits |
| **accessibility-audit-helper.sh** | Full accessibility audit | WCAG compliance |
| **pagespeed** | Performance testing | Core Web Vitals |
| **Playwright test suite** | Project-specific E2E tests | CI/CD, regression testing |

## Related

- `scripts/milestone-validation-worker.sh` — Parent validation worker
- `workflows/milestone-validation.md` — Validation workflow
- `workflows/mission-orchestrator.md` — Mission orchestrator (invokes validation)
- `tools/browser/browser-automation.md` — Browser tool selection guide
- `tools/browser/playwright.md` — Playwright reference
- `scripts/accessibility/playwright-contrast.mjs` — Similar Playwright script pattern
