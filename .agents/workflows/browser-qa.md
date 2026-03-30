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
| **Script** | `scripts/browser-qa-worker.sh` (shell) + `scripts/browser-qa/browser-qa.mjs` (Playwright) |
| **Invoked by** | `milestone-validation-worker.sh --browser-qa` or standalone |
| **Output** | Pass/fail report, screenshots, broken links, console errors, `{output-dir}/qa-report.json` |
| **Prerequisites** | Node.js v18+, Playwright (`npm install playwright && npx playwright install`) |

**Key files:** `scripts/browser-qa-worker.sh`, `scripts/browser-qa/browser-qa.mjs`, `scripts/milestone-validation-worker.sh`, `workflows/milestone-validation.md`, `tools/browser/browser-automation.md`

<!-- AI-CONTEXT-END -->

## When to Use

| Flag | Effect | When |
|------|--------|------|
| `--browser-tests` | Runs project's Playwright test suite | Project has `playwright.config.{ts,js}` |
| `--browser-qa` | Generic visual QA (screenshots, links, errors) | Any UI project; POC-mode missions without test suite |

## Per-Page Checks

| Check | Detects | Severity |
|-------|---------|----------|
| HTTP status | 4xx/5xx responses | Fail |
| Empty page | Body text < 10 chars | Fail |
| Error states | "Application error", hydration failures | Fail |
| Console errors | JS exceptions, uncaught errors | Fail |
| Network errors | Failed fetch/XHR | Fail |
| Broken links | `<a>` hrefs returning 4xx/5xx or timing out | Fail |
| Screenshot | Full-page capture for human review | Info |
| ARIA snapshot | Structural accessibility tree | Info |

**Aggregate report:** pages visited/passed/failed, broken links, console errors, screenshot paths. JSON at `{output-dir}/qa-report.json`.

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

### From Milestone Validation

```bash
milestone-validation-worker.sh mission.md 2 \
  --browser-qa --browser-url http://localhost:3000
milestone-validation-worker.sh mission.md 2 \
  --browser-qa --browser-url http://localhost:3000 \
  --browser-qa-flows '["/", "/about", "/api/health"]'
milestone-validation-worker.sh mission.md 1 \
  --browser-tests --browser-qa --browser-url http://localhost:3000
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All checks passed |
| `1` | Checks failed (issues found) |
| `2` | Configuration error (missing args, Playwright not installed) |

## Flow Definitions

Flows define which pages to visit. Two formats:

```json
["/", "/about", "/contact", "/login"]

[
  {"url": "/", "name": "homepage"},
  {"url": "/login", "name": "login-page"},
  {"url": "/dashboard", "name": "dashboard"}
]
```

With `--mission-file` and `--milestone`, the worker extracts URL-like patterns from the milestone's acceptance criteria.

## Output

- **Screenshots:** `{output-dir}/{hostname}_{path}.png`; on error: `{hostname}_{path}-error.png`
- **JSON report:** `{output-dir}/qa-report.json` -- `baseUrl`, `timestamp`, `viewport`, per-page results (`status`, `title`, `screenshot`, `consoleErrors`, `networkErrors`, `linkResults`, `loadTimeMs`, `passed`, `failures`), top-level `passed`

## Related Tools

| Tool | Purpose | When |
|------|---------|------|
| **browser-qa-worker.sh** | Generic visual QA (this tool) | Milestone validation, smoke testing |
| **playwright-contrast.mjs** | WCAG contrast analysis | Accessibility audits |
| **accessibility-audit-helper.sh** | Full accessibility audit | WCAG compliance |
| **pagespeed** | Performance testing | Core Web Vitals |
| **Playwright test suite** | Project-specific E2E tests | CI/CD, regression testing |

## Related

- `scripts/milestone-validation-worker.sh` -- Parent validation worker
- `workflows/milestone-validation.md` -- Validation workflow
- `workflows/mission-orchestrator.md` -- Mission orchestrator (invokes validation)
- `tools/browser/browser-automation.md` -- Browser tool selection guide
- `tools/browser/playwright.md` -- Playwright reference
- `scripts/accessibility/playwright-contrast.mjs` -- Similar Playwright script pattern
