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
local-browser smoke test and a narrow, billed public-page AI extraction probe;
neither is a like-for-like run of the full benchmark matrix.

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
CLI call succeeded. This **free-tier callback path** is not verified and the attempted
calls have no terminal cost receipts. No inference cache/recovery result or
Stagehand AI success rate can be inferred from these failed attempts. An
authenticated Playwriter lane was not exercised: no selected existing tab or
profile-consent boundary was established. Keep Playwright as the deterministic
default and Playwriter as explicit-only legacy. Do not compare this probe to
the v3 benchmark table.

A follow-up client-side `generate` probe through the installed OpenCode SDK
reached the provider but returned HTTP 403 `FreeTierError`: the free tier is
restricted to use within OpenCode. A separate direct SDK prompt without the
Stagehand callback succeeded, but that does **not** authorize using the free
tier as an embedded model provider. Do not work around this restriction or
count the denied callback as an inference result. The later paid NanoGPT probe
below used the authorized provider instead; it did not bypass the free-tier rule.

### Stagehand v4 NanoGPT public-page AI extraction (2026-09-27; partial comparison)

The reviewed opt-in **offline** harness is
`STAGEHAND_PROBE_MAX_USD=0.05 bash .agents/scripts/stagehand-v4-helper.sh probe offline two-call`.
Run `bash .agents/scripts/tests/test-stagehand-v4-route.sh` for missing-cap,
over-projection, malformed-format, HTTP 403, excess-request and timeout
fixtures. Its JSON receipt uses synthetic token/cost values and null timings:
it does **not** navigate, contact NanoGPT, or measure extraction. `probe live`
is deliberately disabled. The isolated Stagehand project and the configured
OpenCode NanoGPT SDK transport are not installed/verified in this worker
worktree; the historical input/output prices are not a proof of a worst-case
USD ceiling including retries, billing increments and provider overhead.
Neither a 150 s process timeout nor a post-call provider receipt is a hard
spend cap. Do not export credentials to work around this fuse or run the
existing OpenAI `run-example` as a fallback. The live acceptance criterion
remains open pending a verified pre-inference provider-enforced ceiling (or a
trusted bounded transport), current SDK response exports and separate trusted
billing authorization; the offline harness is not a live benchmark.

With the operator's NanoGPT credential already configured in OpenCode (no key
exported or logged), a local Stagehand v4.1.0 browser used a client-side
`generate` callback through the OpenCode SDK. The explicit model was
`nano-gpt/openai/gpt-4o-mini` (provider metadata: $0.15/million input tokens,
$0.60/million output tokens). The callback capped requests at three and each
serialized input at 200,000 characters; the bounded process had a 150 s limit.
The earlier $2 test cap remained in force despite the larger account credit.
This is a probe, not a persistent provider integration or a provider-enforced
spend limit.

All three **corrected** runs on `https://example.com` returned `Example Domain`
from both the deterministic `h1` locator and Stagehand's structured AI
`extract('Extract the heading of this page', ...)`. Each extraction needed two
model calls. Timings exclude page navigation; usage/cost below is the OpenCode
provider's reported sum for those two calls, not an independent account bill.

| Corrected run | Locator after navigation | Stagehand extract after navigation | Model input/output tokens | Reported model cost |
|---------------|--------------------------|-----------------------------------|---------------------------|---------------------|
| 1 | 8 ms | 14,307 ms | 395 / 27 | $0.003954 |
| 2 | 8 ms | 10,021 ms | 399 / 27 | $0.003954 |
| 3 | 10 ms | 12,978 ms | 655 / 27 | $0.003974 |
| **Median** | **8 ms** | **12,978 ms** | — | **$0.003954** |

The three successful extractions total $0.011882 reported model cost. A
separate NanoGPT transport smoke call cost $0.003822. Two earlier callback
attempts failed before producing a Stagehand result: the first returned text
instead of the SDK-required `json_schema`/`structuredContent`; the second
returned fenced JSON and required fence normalization. One of those failures
did not print a terminal cost receipt. A third diagnostic run succeeded at
inference but hit an overly strict one-request guard before extraction
completed ($0.001956 reported). Do not present the successful 3/3 as an
unqualified success rate across all attempts, or report an exact aggregate
provider bill from these partial receipts.

This single stable public page tests heading extraction only. OpenCode's
ambient prompt and caching affect measured model cost and latency; no v4
act/observe, multi-step workflow, alternate model, or authenticated existing
tab was compared. The `h1` locator remains much faster for known structure.
Keep Playwright as the default, retain Stagehand as opt-in for adaptive tasks,
and do not promote Playwriter beyond explicit legacy compatibility. A
selected existing tab plus consent-safe profile isolation is still needed to
evaluate the authenticated lane.

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
