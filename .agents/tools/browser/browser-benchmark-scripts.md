<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Browser Benchmark Scripts

Reference scripts for `browser-benchmark.md`. All implement the same four tests (navigate, formFill, extract, multiStep) against `https://the-internet.herokuapp.com` — 3 runs each, median reported.

## Chapters

| File | Contents |
|------|----------|
| [`browser-benchmark-scripts-01-playwright.md`](browser-benchmark-scripts-01-playwright.md) | Sequential + parallel (multi-context, multi-browser, multi-page) |
| [`browser-benchmark-scripts-02-dev-browser.md`](browser-benchmark-scripts-02-dev-browser.md) | Persistent Chrome via CDP — adapted from Playwright |
| [`browser-benchmark-scripts-03-agent-browser.md`](browser-benchmark-scripts-03-agent-browser.md) | CLI-based sequential + 3 parallel sessions |
| [`browser-benchmark-scripts-04-crawl4ai.md`](browser-benchmark-scripts-04-crawl4ai.md) | navigate + extract only (no form/multi-step); sequential vs parallel |
| [`browser-benchmark-scripts-05-stagehand.md`](browser-benchmark-scripts-05-stagehand.md) | AI-driven act()/extract() — measures cold-start per run |
| [`browser-benchmark-scripts-06-visual-verification.md`](browser-benchmark-scripts-06-visual-verification.md) | Screenshot + ARIA snapshot timing; WARNING: no fullPage:true |

## Tool capability matrix

| Test | Playwright | dev-browser | agent-browser | Crawl4AI | Stagehand |
|------|-----------|-------------|---------------|----------|-----------|
| navigate | yes | yes | yes | yes | yes |
| formFill | yes | yes | yes | no | yes |
| extract | yes | yes | yes | yes | yes |
| multiStep | yes | yes | yes | no | yes |
