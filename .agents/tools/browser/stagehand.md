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

**Custom browsers**: Supports Brave, Edge, and Chrome via `executablePath` in `browserOptions`. Brave provides built-in ad/tracker blocking via Shields without needing extensions. See "Custom Browser Engine" section below.

**Extensions**: Possible via Playwright's `launchPersistentContext` (Stagehand uses Playwright underneath), but untested. Use Playwright instead for extension access. uBlock Origin can be loaded via `--load-extension` in `browserOptions.args`.

**AI Page Understanding**: Built-in - `observe()` returns available actions, `extract()` returns structured data with schemas. Stagehand IS the AI understanding layer. No need for separate ARIA/screenshot analysis.

**Chrome DevTools MCP**: Possible (Stagehand launches Chromium), but adds overhead to an already slow tool. Use Playwright direct + DevTools instead.

**Headless**: Set `headless: true` in config (default for benchmarks).
<!-- AI-CONTEXT-END -->

## Core Primitives

### Act — Natural Language Actions

```javascript
await stagehand.act("click the submit button");
await stagehand.act("fill in the email field with user@example.com");
await stagehand.act("select 'Premium' from the subscription dropdown");
```

### Extract — Structured Data

```javascript
const productInfo = await stagehand.extract(
    "extract product details",
    z.object({
        name: z.string().describe("Product name"),
        price: z.number().describe("Price in USD"),
        rating: z.number().describe("Star rating out of 5"),
        reviews: z.array(z.string()).describe("Customer review texts"),
        inStock: z.boolean().describe("Whether item is in stock")
    })
);
```

### Observe — Discover Available Actions

```javascript
const actions = await stagehand.observe();
const buttons = await stagehand.observe("find all clickable buttons");
const forms = await stagehand.observe("find all form fields");
```

### Agent — Autonomous Workflows

```javascript
const agent = stagehand.agent({
    cua: true, // Enable Computer Use Agent
    model: "google/gemini-2.5-computer-use-preview-10-2025"
});
await agent.execute("complete the checkout process");
await agent.execute("research competitor pricing and create a report");
```

## Configuration

### Environment Variables

`~/.aidevops/stagehand/.env`:

```bash
# AI Provider (choose one)
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_api_key_here

# Browser
STAGEHAND_ENV=LOCAL          # LOCAL or BROWSERBASE
STAGEHAND_HEADLESS=false     # Show browser window
STAGEHAND_VERBOSE=1          # Logging level
STAGEHAND_DEBUG_DOM=true     # Debug DOM interactions

# Optional: Browserbase (cloud browsers)
BROWSERBASE_API_KEY=your_browserbase_api_key_here
BROWSERBASE_PROJECT_ID=your_browserbase_project_id_here
```

### Advanced Configuration

```javascript
const stagehand = new Stagehand({
    env: "LOCAL",
    verbose: 1,
    debugDom: true,
    headless: false,
    browserOptions: {
        args: ["--disable-web-security", "--disable-features=VizDisplayCompositor"]
    },
    modelName: "gpt-4o", // or "claude-sonnet-4-6"
    modelClientOptions: { apiKey: process.env.OPENAI_API_KEY }
});
```

### Custom Browser Engine (Brave, Edge, Chrome)

Pass `executablePath` via `browserOptions`. Extensions may require headed mode; `--headless=new` supports extensions in newer Chromium.

```javascript
const stagehand = new Stagehand({
    env: "LOCAL",
    headless: false,
    browserOptions: {
        executablePath: '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
        args: [
            '--load-extension=/path/to/ublock-origin-unpacked',
            '--disable-extensions-except=/path/to/ublock-origin-unpacked',
        ],
    },
    modelName: "gpt-4o",
    modelClientOptions: { apiKey: process.env.OPENAI_API_KEY }
});
```

See [`browser-automation.md`](browser-automation.md#custom-browser-engine-support) for browser executable paths (macOS, Linux, Windows) and additional browser examples.

## Basic Usage Example

```javascript
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const stagehand = new Stagehand({ env: "LOCAL", verbose: 1 });
await stagehand.init();
await stagehand.page.goto("https://example.com");
await stagehand.act("click the login button");

const data = await stagehand.extract(
    "get the price and title",
    z.object({ price: z.number(), title: z.string() })
);

await stagehand.close();
```

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

- **Docs**: https://docs.stagehand.dev
- **GitHub**: https://github.com/browserbase/stagehand
- **Quickstart**: https://docs.stagehand.dev/v3/first-steps/quickstart
- **Browser Automation**: `.agents/tools/browser/browser-automation.md`
- **MCP Integrations**: `.agents/aidevops/mcp-integrations.md`
- **Quality Standards**: `.agents/tools/code-review/code-standards.md`
