---
description: Run browser tool benchmarks to compare performance across all installed tools
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  grep: true
  task: true
---

# Browser Tool Benchmarking Agent

Run standardised benchmarks across all browser automation tools and update `browser-automation.md` with results.

## Quick Start

```bash
/browser-benchmark              # Run all benchmarks
/browser-benchmark playwright   # Run specific tool only
/browser-benchmark --test navigate
/browser-benchmark --update-docs
```

## Test Matrix

All tests use `https://the-internet.herokuapp.com`. Run each test 3 times per tool, report median. Network variance ~0.2-0.5s.

| Test | Measures |
|------|----------|
| Navigate + Screenshot | Cold page load + render capture |
| Form Fill (4 fields) | Input interaction + submit + navigation |
| Data Extraction (5 rows) | DOM query + structured data return |
| Multi-step (click + nav) | Sequential interaction + URL change |
| Reliability (3 runs) | Variance across repeated Navigate runs |

## Tool Coverage

| Tool | Scope | Setup | Notes |
|------|-------|-------|-------|
| Playwright | Full | `mkdir -p ~/.aidevops/playwright-bench && cd ~/.aidevops/playwright-bench && npm init -y && npm i playwright` | |
| dev-browser | Full | `dev-browser-helper.sh setup` | Server must be running (`dev-browser-helper.sh start-headless`) |
| agent-browser | Full | `agent-browser-helper.sh setup` | First run slower (daemon startup) — discard or note separately |
| Crawl4AI | Navigate + extract only | `python3 -m venv ~/.aidevops/crawl4ai-venv && source ~/.aidevops/crawl4ai-venv/bin/activate && pip install crawl4ai` | No form fill or multi-step |
| Stagehand | Full (AI-dependent latency) | `mkdir -p ~/.aidevops/stagehand-bench && cd ~/.aidevops/stagehand-bench && npm init -y && npm i @browserbasehq/stagehand` | Needs `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`; note model used |
| Playwriter | Full | `npm i -g playwriter` | Requires manual extension activation (localhost:19988) — may skip in automated runs |

## Running Benchmarks

Scripts: `~/.aidevops/.agent-workspace/work/browser-bench/`. Full source: `browser-benchmark-scripts.md`.

```bash
cd ~/.aidevops/.agent-workspace/work/browser-bench/
node bench-playwright.mjs | tee results-playwright.json
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx bench.ts | tee ~/results-dev-browser.json
bash bench-agent-browser.sh | tee results-agent-browser.txt
source ~/.aidevops/crawl4ai-venv/bin/activate && python bench-crawl4ai.py | tee results-crawl4ai.json
OPENAI_API_KEY=... node bench-stagehand.mjs | tee results-stagehand.json
```

## Updating Documentation

After benchmarks, update `browser-automation.md` Performance Benchmarks table:

1. Median of 3 runs per test; bold fastest time per row
2. Update "Key insight" section if relative performance changed
3. Note date and environment (`date`, `uname -a`, `node --version`, `python3 --version`)

## Adding New Tools

1. Add benchmark script per patterns in `browser-benchmark-scripts.md`
2. Add tool to Tool Coverage table; run full suite
3. Update `browser-automation.md` tables (Performance, Feature Matrix, Parallel, Extensions)
4. Update Test Matrix above; test parallel capabilities, extension support, visual verification
