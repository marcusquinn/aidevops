---
description: Run browser tool benchmarks to compare performance across all installed tools
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Browser Tool Benchmarking Agent

Runs standardised benchmarks across all browser automation tools and updates `browser-automation.md` with results. Scripts in `browser-benchmark-scripts.md`.

```bash
/browser-benchmark              # Run all benchmarks
/browser-benchmark playwright   # Run specific tool only
/browser-benchmark --test navigate
/browser-benchmark --update-docs
```

## Test Matrix

Target: `https://the-internet.herokuapp.com`. 3 runs per tool, report median. Network variance ~0.2-0.5s.

| Test | Measures |
|------|----------|
| Navigate + Screenshot | Cold page load + render capture |
| Form Fill (4 fields) | Input interaction + submit + navigation |
| Data Extraction (5 rows) | DOM query + structured data return |
| Multi-step (click + nav) | Sequential interaction + URL change |
| Reliability (3 runs) | Variance across repeated Navigate runs |

## Tool Coverage

| Tool | Scope | Setup |
|------|-------|-------|
| Playwright | Full | `npm init -y && npm i playwright` in `~/.aidevops/playwright-bench/` |
| dev-browser | Full | `dev-browser-helper.sh setup` (server: `dev-browser-helper.sh start-headless`) |
| agent-browser | Full | `agent-browser-helper.sh setup` (first run slower — discard or note) |
| Crawl4AI | Navigate + extract only | `python3 -m venv ~/.aidevops/crawl4ai-venv && pip install crawl4ai` |
| Stagehand v3 (historical script) | Full (AI-dependent latency) | Existing `bench-stagehand.mjs` targets the older SDK; keep its result separate from v4. |
| Stagehand v4.1.0 | Opt-in isolated local browser; AI extraction needs explicit model/key | `bash .agents/scripts/stagehand-v4-helper.sh setup`; a like-for-like v4 benchmark is not yet implemented. |
| Playwriter (legacy, not recommended) | Full | Retained only for historical comparison; skip unless explicitly benchmarking an existing setup |

## Running Benchmarks

The existing Stagehand script is v3-only. Do not run it against the isolated v4
project or report its historical measurements as v4. The v4 route has a verified
no-model local-browser smoke test, not a billed AI performance comparison.

### Stagehand v4 public-page probe (2026-09-26; not a full benchmark)

On the public `https://example.com` page, one isolated Stagehand v4.1.0 browser
run returned `Example Domain` from `page.locator('h1').textContent()` in 9 ms
**after navigation**. A separate direct OpenCode CLI inference over a short
excerpt of that page's accessibility snapshot returned `{"heading":"Example Domain"}`. Its bounded
process ran for 19.5 s and reported $0 in provider cost (27,755 total tokens,
including 27,648 input tokens). These are single observations, not medians;
the CLI's large ambient prompt makes its duration
unsuitable as a Stagehand inference-latency estimate.

Two attempts to route this free model through Stagehand's client-side `generate`
callback timed out at 90 s and 120 s, respectively. A standalone Node child
process invoking the same OpenCode CLI also timed out at 60 s, while the direct
CLI call succeeded. The callback path is **not verified** and the attempted
calls have no terminal cost receipts. No inference cache/recovery result or
Stagehand AI success rate can be inferred. An authenticated Playwriter lane
was not exercised: no selected existing tab or profile-consent boundary was
established. Keep Playwright as the deterministic default and Playwriter as
explicit-only legacy until a bounded model transport and consent-safe comparison
can be verified. Do not compare this probe to the v3 benchmark table.

A follow-up client-side `generate` probe through the installed OpenCode SDK
reached the provider but returned HTTP 403 `FreeTierError`: the free tier is
restricted to use within OpenCode. A separate direct SDK prompt without the
Stagehand callback succeeded, but that does **not** authorize using the free
tier as an embedded model provider. Do not work around this restriction or
count the denied callback as an inference result. A further Stagehand AI test
needs an approved provider transport with credentials supplied through secure
storage and a per-run cost limit; it must not silently fall back to a paid model.

```bash
cd ~/.aidevops/.agent-workspace/work/browser-bench/
node bench-playwright.mjs | tee results-playwright.json
bash bench-agent-browser.sh | tee results-agent-browser.txt
source ~/.aidevops/crawl4ai-venv/bin/activate && python bench-crawl4ai.py | tee results-crawl4ai.json
OPENAI_API_KEY=... node bench-stagehand.mjs | tee results-stagehand.json
# dev-browser: bun x tsx ~/.aidevops/dev-browser/skills/dev-browser/bench.ts | tee ~/results-dev-browser.json
```

## Updating Documentation

Update the Performance Benchmarks table in `browser-automation.md`:

1. Median of 3 runs per test; bold fastest time per row; label the Stagehand SDK major version
2. Update "Key insight" section if relative performance changed
3. Record environment, model/token spend, cache hits and failures; request explicit model-billing consent before running AI benchmarks

## Adding New Tools

1. Add benchmark script per patterns in `browser-benchmark-scripts.md`
2. Add tool to Tool Coverage table; run full suite
3. Update `browser-automation.md` tables (Performance, Feature Matrix, Parallel, Extensions)
