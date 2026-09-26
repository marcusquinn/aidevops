---
description: Stagehand AI browser automation with natural language
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Stagehand AI Browser Automation Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

**Stagehand v4.1.0 (opt-in, isolated local browser):** `bash .agents/scripts/stagehand-v4-helper.sh setup`. This pins the reviewed JS SDK and Zod in a separate project, leaving existing v3 installs untouched. `status` verifies exact installed versions; `run-example` requires explicit `OPENAI_API_KEY` and `STAGEHAND_MODEL=openai/<supported-model>` and makes a model-backed call (provider charges may apply). The example launches its own headless Chrome instance, closes both the SDK and browser in `finally`, and never attaches to a live user profile. No globally exposed MCP tools are added.

**Existing v3 compatibility:** The `stagehand-helper.sh` and `stagehand-python-helper.sh` commands below, and `stagehand-examples.md` / `stagehand-python.md`, describe the older API. Do not assume they work with v4. Keep v3 until its Python and downstream callers have been migrated and tested independently.

- **Purpose**: AI-powered browser automation with natural language control
- **Languages**: JavaScript (npm) + Python (pip)
- **Setup JS**: `bash .agents/scripts/stagehand-helper.sh setup`
- **Setup Python**: `bash .agents/scripts/stagehand-python-helper.sh setup`
- **Setup Both**: `bash .agents/scripts/setup-mcp-integrations.sh stagehand-both`

**Core Primitives**:
- `act("click login button")` - Natural language actions
- `extract("get price", z.number())` - Structured data with Zod/Pydantic schemas
- `observe()` - Discover available actions on page
- `agent.execute("complete checkout")` - v3 only; v4 removes `agent()`

**Config**: `~/.aidevops/stagehand/.env`
**Env Vars**: `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`, `STAGEHAND_ENV=LOCAL`, `STAGEHAND_HEADLESS=false`

**Key Advantage**: Self-healing automation that adapts when websites change

**Performance**: The 2026-01-24 figures below were measured against the older integration, not v4. Do not use them to assert current latency, reliability, or price. Local v4 needs an explicit model and API key; use Playwright directly for deterministic steps without model calls.

**Parallel**: Multiple Stagehand instances (each launches own browser). Full isolation but slow due to AI overhead per instance. For parallel speed, use Playwright direct.

**Custom browsers (v4)**: `localBrowser.launch({ executablePath })` uses a separate Chrome/Chromium-family browser. The bundled example uses the SDK's default local Chrome; custom browsers and existing profiles are not tested in this route.

**Extensions/consent**: v4 runs an extension in its owned browser and `localBrowser.connect({ cdpUrl })` can attach over CDP, but CDP access is broader than user-selected tabs. Do not connect this route to a live browser, import cookies, or claim it replaces Playwright Extension or legacy Playwriter for consent-scoped authenticated tabs.

**AI Page Understanding**: Built-in - `observe()` returns available actions, `extract()` returns structured data with schemas. Stagehand IS the AI understanding layer. No need for separate ARIA/screenshot analysis.

**Chrome DevTools MCP**: Possible (Stagehand launches Chromium), but adds overhead to an already slow tool. Use Playwright direct + DevTools instead.

**Headless (v4)**: `localBrowser.launch({ headless: true })` in the isolated example.
<!-- AI-CONTEXT-END -->

## Configuration

### v4 decision and trade-offs

| Scenario | Preferred route | Evidence / boundary |
|----------|-----------------|---------------------|
| Repeatable isolated flow, stable selectors | Standalone Playwright | No per-step model cost; existing browser benchmarks favour Playwright. |
| Unknown/changing page or typed AI extraction | Opt-in Stagehand v4 after model/cost consent | v4 separates deterministic `browser.context`/`page.locator()` from `act`/`extract`/`observe`; results contain `data` and `metadata` for token/caching diagnostics. |
| User-selected existing authenticated tabs | Playwright Extension; Playwriter only for explicit legacy compatibility | v4 CDP connection does not demonstrate selected-tab consent/profile isolation, so no replacement or headless-worker access is approved. |

v4 removes `agent()` and changes `new Stagehand().init()` to `Stagehand.create({ browser })`; the browser factory owns the process. The opt-in helper is the lowest-context bounded execution path; no OpenCode MCP registry entry is appropriate until profile/consent isolation and lifecycle cleanup are demonstrated. Server-side caching requires Browserbase; local v4 has no managed cache. Browserbase adds usage-based browser charges in addition to model charges. No fresh comparable v4/Playwright/Playwriter benchmark is available; do not substitute the dated v3 timings. Before enabling a wider route, measure end-to-end latency, task success, model tokens/cost, cache hits, recovery and browser/profile cleanup on the same representative scenarios. Model-backed side effects must not be retried blindly.

Upstream references: [v4 quickstart](https://docs.stagehand.dev/v4/first-steps/quickstart), [browser ownership](https://docs.stagehand.dev/v4/configuration/browser), [v3 migration](https://docs.stagehand.dev/v4/migrations/v3).

### v3 configuration (legacy)

`~/.aidevops/stagehand/.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here      # or ANTHROPIC_API_KEY
STAGEHAND_ENV=LOCAL                           # LOCAL or BROWSERBASE
STAGEHAND_HEADLESS=false                      # show browser window
STAGEHAND_VERBOSE=1                           # logging level
STAGEHAND_DEBUG_DOM=true                      # debug DOM interactions
BROWSERBASE_API_KEY=your_key_here             # optional cloud browsers
BROWSERBASE_PROJECT_ID=your_project_id_here
```

Advanced JS config (`modelName`, `browserOptions`, `executablePath` for custom browsers): see [`stagehand-examples.md`](stagehand-examples.md). Browser executable paths (macOS/Linux/Windows): [`browser-automation.md`](browser-automation.md#custom-browser-engine-support).

## Helper Commands

```bash
bash .agents/scripts/stagehand-helper.sh install          # Install
bash .agents/scripts/stagehand-helper.sh setup            # Complete setup
bash .agents/scripts/stagehand-helper.sh status           # Check installation
bash .agents/scripts/stagehand-helper.sh create-example   # Create example script
bash .agents/scripts/stagehand-helper.sh run-example      # Run basic example
bash .agents/scripts/stagehand-helper.sh logs             # View logs
bash .agents/scripts/stagehand-helper.sh clean            # Clean cache and logs
```

## Resources

- **Examples (JS)**: `.agents/tools/browser/stagehand-examples.md`
- **Python SDK**: `.agents/tools/browser/stagehand-python.md`
- **Browser Automation**: `.agents/tools/browser/browser-automation.md`
- **MCP Integrations**: `.agents/aidevops/mcp-integrations.md`
- **Docs**: https://docs.stagehand.dev
- **GitHub**: https://github.com/browserbase/stagehand
