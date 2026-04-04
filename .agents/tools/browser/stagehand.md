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

- **Purpose**: AI-powered browser automation with natural language control
- **Languages**: JavaScript (npm) + Python (pip)
- **Setup JS**: `bash .agents/scripts/stagehand-helper.sh setup`
- **Setup Python**: `bash .agents/scripts/stagehand-python-helper.sh setup`
- **Setup Both**: `bash .agents/scripts/setup-mcp-integrations.sh stagehand-both`

**Core Primitives**:
- `act("click login button")` - Natural language actions
- `extract("get price", z.number())` - Structured data with Zod/Pydantic schemas
- `observe()` - Discover available actions on page
- `agent.execute("complete checkout")` - Autonomous workflows

**Config**: `~/.aidevops/stagehand/.env`
**Env Vars**: `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`, `STAGEHAND_ENV=LOCAL`, `STAGEHAND_HEADLESS=false`

**Key Advantage**: Self-healing automation that adapts when websites change

**Performance**: Navigate 7.7s, form fill 2.6s, extraction 3.5s, reliability 1.7s avg.
Slowest tool due to AI model overhead. Without API key, works as a Playwright wrapper (use Playwright direct instead for speed).

**Parallel**: Multiple Stagehand instances (each launches own browser). Full isolation but slow due to AI overhead per instance. For parallel speed, use Playwright direct.

**Custom browsers**: Supports Brave, Edge, and Chrome via `executablePath` in `browserOptions`. Brave provides built-in ad/tracker blocking via Shields without needing extensions. See [`stagehand-examples.md`](stagehand-examples.md) for config examples.

**Extensions**: Possible via Playwright's `launchPersistentContext` (Stagehand uses Playwright underneath), but untested. Use Playwright instead for extension access. uBlock Origin can be loaded via `--load-extension` in `browserOptions.args`.

**AI Page Understanding**: Built-in - `observe()` returns available actions, `extract()` returns structured data with schemas. Stagehand IS the AI understanding layer. No need for separate ARIA/screenshot analysis.

**Chrome DevTools MCP**: Possible (Stagehand launches Chromium), but adds overhead to an already slow tool. Use Playwright direct + DevTools instead.

**Headless**: Set `headless: true` in config (default for benchmarks).
<!-- AI-CONTEXT-END -->

## Configuration

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
