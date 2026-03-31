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
| **Scripts** | `scripts/browser-qa-worker.sh` (shell) + `scripts/browser-qa/browser-qa.mjs` (Playwright) |
| **Entry points** | Standalone or `milestone-validation-worker.sh --browser-qa` |
| **Purpose** | Visual smoke QA: screenshots, broken links, console/network errors, empty/error pages |
| **Output** | Text/JSON report plus `{output-dir}/qa-report.json` and screenshots |
| **Prerequisites** | Node.js v18+, Playwright (`npm install playwright && npx playwright install`) |

**Key files:** `scripts/browser-qa-worker.sh`, `scripts/browser-qa/browser-qa.mjs`, `scripts/milestone-validation-worker.sh`, `workflows/milestone-validation.md`, `tools/browser/browser-automation.md`

<!-- AI-CONTEXT-END -->

## When to Use

| Flag | Runs | Use when |
|------|------|----------|
| `--browser-tests` | Project Playwright test suite | Repo already has `playwright.config.{ts,js}` |
| `--browser-qa` | Generic browser smoke QA | Any UI project, especially POC/milestone validation without a dedicated suite |

## Checks

| Check | Detects | Result |
|-------|---------|--------|
| HTTP status | 4xx/5xx responses | Fail |
| Empty page | Body text under 10 chars | Fail |
| Error states | `Application error`, hydration failures | Fail |
| Console errors | JS exceptions, uncaught errors | Fail |
| Network errors | Failed fetch/XHR | Fail |
| Broken links | `<a>` targets returning 4xx/5xx or timing out | Fail |
| Screenshot | Full-page capture for review | Info |
| ARIA snapshot | Accessibility tree snapshot | Info |

Aggregate output includes visited/passed/failed pages, broken links, console errors, and screenshot paths. JSON summary: `{output-dir}/qa-report.json`.

## Usage

### Standalone

```bash
browser-qa-worker.sh --url http://localhost:3000
browser-qa-worker.sh --url http://localhost:3000 \
  --flows '["/", "/about", "/login", "/dashboard"]'
browser-qa-worker.sh --url http://localhost:8080 \
  --output-dir ~/Git/myproject/todo/missions/m001/assets/qa
browser-qa-worker.sh --url http://localhost:3000 --format json
browser-qa-worker.sh --url http://localhost:3000 --no-check-links
browser-qa-worker.sh --url http://localhost:3000 \
  --mission-file ~/Git/myproject/todo/missions/m001/mission.md \
  --milestone 2
```

### Via milestone validation

```bash
milestone-validation-worker.sh mission.md 2 \
  --browser-qa --browser-url http://localhost:3000
milestone-validation-worker.sh mission.md 2 \
  --browser-qa --browser-url http://localhost:3000 \
  --browser-qa-flows '["/", "/about", "/api/health"]'
milestone-validation-worker.sh mission.md 1 \
  --browser-tests --browser-qa --browser-url http://localhost:3000
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | All checks passed |
| `1` | QA found failures |
| `2` | Configuration error (missing args, Playwright unavailable) |

## Flows and output

Flows define the pages to visit. Supported formats:

```json
["/", "/about", "/contact", "/login"]

[
  {"url": "/", "name": "homepage"},
  {"url": "/login", "name": "login-page"},
  {"url": "/dashboard", "name": "dashboard"}
]
```

With `--mission-file` and `--milestone`, the worker extracts URL-like patterns from the milestone acceptance criteria.

- Screenshots: `{output-dir}/{hostname}_{path}.png`; failures also get `{hostname}_{path}-error.png`
- JSON: `{output-dir}/qa-report.json` with `baseUrl`, `timestamp`, `viewport`, top-level `passed`, and per-page results (`status`, `title`, `screenshot`, `consoleErrors`, `networkErrors`, `linkResults`, `loadTimeMs`, `passed`, `failures`)

## Related

| Tool | Purpose | Use when |
|------|---------|----------|
| `browser-qa-worker.sh` | Generic browser smoke QA | Milestone validation, manual smoke checks |
| `playwright-contrast.mjs` | WCAG contrast analysis | Accessibility audits |
| `accessibility-audit-helper.sh` | Broader accessibility audit | WCAG compliance reviews |
| `pagespeed` | Performance testing | Core Web Vitals work |
| Project Playwright suite | Project-specific E2E coverage | CI/CD and regression testing |

- `scripts/milestone-validation-worker.sh` - parent validation worker
- `workflows/milestone-validation.md` - validation workflow
- `workflows/mission-orchestrator.md` - mission orchestrator
- `tools/browser/browser-automation.md` - browser tool selection guide
- `tools/browser/playwright.md` - Playwright reference
- `scripts/accessibility/playwright-contrast.mjs` - related Playwright script pattern
