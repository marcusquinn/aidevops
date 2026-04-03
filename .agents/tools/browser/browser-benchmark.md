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

# Browser Tool Benchmarking Agent

Run standardised benchmarks across all browser automation tools and update `browser-automation.md` with results.

```bash
/browser-benchmark              # Run all benchmarks
/browser-benchmark playwright   # Run specific tool only
/browser-benchmark --test navigate
/browser-benchmark --update-docs
```

## Test Matrix

Target: `https://the-internet.herokuapp.com`. Run each test 3 times per tool, report median.

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
| Stagehand | Full (AI-dependent latency) | `npm init -y && npm i @browserbasehq/stagehand` in `~/.aidevops/stagehand-bench/` — needs `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` |
| Playwriter | Full | `npm i -g playwriter` — requires manual extension activation (localhost:19988); may skip in automated runs |

## Running Benchmarks

Scripts: `~/.aidevops/.agent-workspace/work/browser-bench/`. Full source: `browser-benchmark-scripts.md`. Network variance ~0.2-0.5s — use median of 3 runs.

```bash
cd ~/.aidevops/.agent-workspace/work/browser-bench/
node bench-playwright.mjs | tee results-playwright.json
bash bench-agent-browser.sh | tee results-agent-browser.txt
source ~/.aidevops/crawl4ai-venv/bin/activate && python bench-crawl4ai.py | tee results-crawl4ai.json
OPENAI_API_KEY=... node bench-stagehand.mjs | tee results-stagehand.json
# dev-browser: cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx bench.ts | tee ~/results-dev-browser.json
```

## Updating Documentation

After benchmarks, update the Performance Benchmarks table in `browser-automation.md`:

1. Median of 3 runs per test; bold fastest time per row
2. Update "Key insight" section if relative performance changed
3. Note date and environment: `date && uname -a && node --version && python3 --version`

## Adding New Tools

1. Add benchmark script per patterns in `browser-benchmark-scripts.md`
2. Add tool to Tool Coverage table; run full suite
3. Update `browser-automation.md` tables (Performance, Feature Matrix, Parallel, Extensions)
