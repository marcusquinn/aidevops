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

Run standardised benchmarks across all browser automation tools and update documentation with results.

## Quick Start

```bash
/browser-benchmark              # Run all benchmarks
/browser-benchmark playwright   # Run specific tool only
/browser-benchmark --test navigate
/browser-benchmark --update-docs
```

## Test Matrix

All tests use `https://the-internet.herokuapp.com`. Run each test 3 times per tool, report median.

| Test | What it measures |
|------|-----------------|
| Navigate + Screenshot | Cold page load + render capture |
| Form Fill (4 fields) | Input interaction + submit + navigation |
| Data Extraction (5 rows) | DOM query + structured data return |
| Multi-step (click + nav) | Sequential interaction + URL change |
| Reliability (3 runs) | Variance across repeated Navigate runs |

**Tool coverage:** Playwright (full), dev-browser (full), agent-browser (full), Crawl4AI (navigate + extract only), Stagehand (full, AI-dependent latency). Playwriter requires manual extension activation — may skip in automated runs.

## Prerequisites

```bash
#!/bin/bash
echo "=== Browser Tool Availability ==="

if command -v npx &>/dev/null && [ -d ~/.aidevops/playwright-bench/node_modules/playwright ]; then
  echo "[OK] Playwright direct"
else
  echo "[--] Playwright direct (run: mkdir -p ~/.aidevops/playwright-bench && cd ~/.aidevops/playwright-bench && npm init -y && npm i playwright)"
fi

if [ -d ~/.aidevops/dev-browser/skills/dev-browser ]; then
  if curl -s --max-time 2 http://localhost:9222/json/version &>/dev/null; then
    echo "[OK] dev-browser (server running)"
  else
    echo "[!!] dev-browser (installed, server not running - run: dev-browser-helper.sh start-headless)"
  fi
else
  echo "[--] dev-browser (run: dev-browser-helper.sh setup)"
fi

command -v agent-browser &>/dev/null && echo "[OK] agent-browser" || echo "[--] agent-browser (run: agent-browser-helper.sh setup)"

[ -f ~/.aidevops/crawl4ai-venv/bin/python ] && echo "[OK] Crawl4AI (venv)" || \
  echo "[--] Crawl4AI (run: python3 -m venv ~/.aidevops/crawl4ai-venv && source ~/.aidevops/crawl4ai-venv/bin/activate && pip install crawl4ai)"

npx playwriter --version &>/dev/null 2>&1 && echo "[!!] Playwriter (needs extension active - check localhost:19988)" || \
  echo "[--] Playwriter (run: npm i -g playwriter)"

[ -d ~/.aidevops/stagehand-bench/node_modules/@browserbasehq/stagehand ] && \
  echo "[OK] Stagehand (needs OPENAI_API_KEY or ANTHROPIC_API_KEY)" || \
  echo "[--] Stagehand (run: mkdir -p ~/.aidevops/stagehand-bench && cd ~/.aidevops/stagehand-bench && npm init -y && npm i @browserbasehq/stagehand)"
```

## Running Benchmarks

Scripts live in `~/.aidevops/.agent-workspace/work/browser-bench/`. Full source: `browser-benchmark-scripts.md`.

```bash
# 1. Check prerequisites (above)
# 2. Run each tool
cd ~/.aidevops/.agent-workspace/work/browser-bench/
node bench-playwright.mjs | tee results-playwright.json
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx bench.ts | tee ~/results-dev-browser.json
bash bench-agent-browser.sh | tee results-agent-browser.txt
source ~/.aidevops/crawl4ai-venv/bin/activate && python bench-crawl4ai.py | tee results-crawl4ai.json
OPENAI_API_KEY=... node bench-stagehand.mjs | tee results-stagehand.json
# 3. Compile results and update browser-automation.md
```

## Interpreting Results

- **Cold start**: First agent-browser run is slower (daemon startup) — discard or note separately
- **Network variance**: Times vary ~0.2-0.5s — use median of 3
- **Stagehand API latency**: Depends on OpenAI/Anthropic response time — note model used
- **Crawl4AI**: Cannot do form fill or multi-step (extraction only)
- **Playwriter**: Requires manual extension activation — may skip in automated runs

## Updating Documentation

After running benchmarks, update the Performance Benchmarks table in `browser-automation.md`:

1. Take median of 3 runs per test
2. Bold the fastest time per row
3. Update the "Key insight" section if relative performance changed
4. Note the date and environment

```bash
echo "Date: $(date +%Y-%m-%d)"
echo "macOS: $(sw_vers -productVersion)"
echo "Chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
echo "Node: $(node --version)"
echo "Bun: $(bun --version 2>/dev/null || echo 'N/A')"
echo "Python: $(python3 --version)"
```

## Adding New Tools

1. Add a benchmark script following the patterns in `browser-benchmark-scripts.md`
2. Add the tool to the prerequisites check (above)
3. Run the full suite including the new tool
4. Update `browser-automation.md` tables (Performance, Feature Matrix, Parallel, Extensions)
5. Update this file's test matrix
6. Test parallel capabilities, extension support, and visual verification
