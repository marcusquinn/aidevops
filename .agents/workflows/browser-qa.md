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

| Item | Value |
|------|-------|
| **Script** | `scripts/browser-qa-worker.sh` (shell wrapper) + `scripts/browser-qa/browser-qa.mjs` (Playwright engine) |
| **Invoked by** | `milestone-validation-worker.sh --browser-qa` or standalone |
| **Output** | Pass/fail report, screenshots, broken link list, console errors, `{output-dir}/qa-report.json` |

**Key files:**

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

Use `--browser-qa` when: no Playwright test suite, quick visual smoke test needed, or acceptance criteria reference specific pages/flows.

## What It Checks

**Per-page:**

| Check | Detects | Severity |
|-------|---------|----------|
| HTTP status | 4xx/5xx responses | Fail |
| Empty page | Body text < 10 characters | Fail |
| Error states | "Application error", hydration failures | Fail |
| Console errors | JS exceptions, uncaught errors | Fail |
| Network errors | Failed fetch/XHR requests | Fail |
| Broken links | `<a>` hrefs returning 4xx/5xx or timing out | Fail |
| Screenshot | Full-page screenshot for human review | Info |
| ARIA snapshot | Structural accessibility tree | Info |

**Aggregate report:** total pages visited/passed/failed, broken links, console errors, screenshot paths, JSON at `{output-dir}/qa-report.json`.

## Usage

### Standalone

```bash
# Basic
browser-qa-worker.sh --url http://localhost:3000

# Multiple pages
browser-qa-worker.sh --url http://localhost:3000 \
  --flows '["/", "/about", "/login", "/dashboard"]'

# Custom output directory
browser-qa-worker.sh --url http://localhost:8080 \
  --output-dir ~/Git/myproject/todo/missions/m001/assets/qa

# JSON output
browser-qa-worker.sh --url http://localhost:3000 --format json

# Skip link checking (faster)
browser-qa-worker.sh --url http://localhost:3000 --no-check-links

# Mission-aware (extracts flows from acceptance criteria)
browser-qa-worker.sh --url http://localhost:3000 \
  --mission-file ~/Git/myproject/todo/missions/m001/mission.md \
  --milestone 2
```

### From Milestone Validation

```bash
milestone-validation-worker.sh mission.md 2 \
  --browser-qa --browser-url http://localhost:3000

# With custom flows
milestone-validation-worker.sh mission.md 2 \
  --browser-qa --browser-url http://localhost:3000 \
  --browser-qa-flows '["/", "/about", "/api/health"]'

# Both flags together
milestone-validation-worker.sh mission.md 1 \
  --browser-tests --browser-qa --browser-url http://localhost:3000
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All QA checks passed |
| `1` | QA checks failed (issues found) |
| `2` | Configuration error (missing args, Playwright not installed) |

## Flow Definitions

Flows define which pages to visit. Three formats:

```json
// Simple URL list
["/", "/about", "/contact", "/login"]

// Named flows with metadata
[
  {"url": "/", "name": "homepage"},
  {"url": "/login", "name": "login-page"},
  {"url": "/dashboard", "name": "dashboard"}
]
```

**From mission file:** When `--mission-file` and `--milestone` are provided, the worker extracts URL-like patterns (`/about`, `/dashboard`, `/api/health`) from the milestone's acceptance criteria section.

## Output

- **Screenshots:** `{output-dir}/{hostname}_{path}.png`; on error: `{hostname}_{path}-error.png`
- **JSON report:** `{output-dir}/qa-report.json` — includes `baseUrl`, `timestamp`, `viewport`, per-page results (`status`, `title`, `screenshot`, `consoleErrors`, `networkErrors`, `linkResults`, `loadTimeMs`, `passed`, `failures`), and top-level `passed`

## Prerequisites

- Node.js v18+
- Playwright: `npm install playwright && npx playwright install` (Chromium used by default)

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
