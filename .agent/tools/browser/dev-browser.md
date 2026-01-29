---
description: Stateful browser automation with persistent Playwright server
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

# Dev-Browser - Stateful Browser Automation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Stateful browser automation with persistent page state AND browser profile
- **Runtime**: Bun + Playwright (pages survive script executions)
- **Server**: `~/.aidevops/dev-browser/server.sh` (port 9222)
- **Profile**: `~/.aidevops/dev-browser/skills/dev-browser/profiles/browser-data/`
- **Scripts**: Execute via `bun x tsx` inline scripts
- **Install**: `bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup`

**Key Advantages**:
- **Near-Playwright speed**: Navigate 1.4s, form fill 1.3s, extraction 1.1s
- **Persistent profile**: Cookies, localStorage, extensions survive server restarts
- **Stateful pages**: Pages persist across script executions within a session
- **Highly consistent**: 1.07s avg reliability with only ±0.02s variance
- **Codebase-aware**: Read source code to write selectors directly
- **LLM-friendly**: ARIA snapshots for element discovery
- **Headless mode**: `start-headless` for no visible window

**Profile Persistence** (survives server restarts):
- Cookies (stay logged into sites)
- localStorage and sessionStorage
- Browser cache
- Extension data (install extensions in headed mode, persists across restarts)

**Extensions**: Install in headed mode (`start` not `start-headless`), then extensions persist in profile. Password managers need manual unlock once per session. uBlock Origin can be installed in the profile for ad/tracker blocking.

**Custom browser**: Dev-browser uses Playwright's bundled Chromium by default. To use Brave, Edge, or Chrome instead, modify the server launch configuration to pass `executablePath`. Alternatively, use Brave for built-in ad blocking without needing uBlock Origin. See "Custom Browser Engine" section below.

**Parallel**: Named pages (`client.page("name")`) share the same profile (not isolated). For isolation, use Playwright direct with multiple contexts.

**AI Page Understanding**: Use ARIA snapshots (`client.getAISnapshot("main")`) - returns structured element tree with refs. Faster and cheaper than screenshots for AI automation.

**Chrome DevTools MCP**: Already on port 9222 - connect via `npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222` for Lighthouse, network monitoring, CSS coverage.

**When to Use**:
- Testing local dev servers (localhost:3000, etc.)
- Multi-step workflows (login -> navigate -> action)
- Iterative debugging with visual feedback
- When you need to stay logged into sites across sessions
- When you have source code access for selectors
- When you want Chrome DevTools MCP inspection alongside automation

**When NOT to Use**:
- Need to use YOUR existing Chrome profile -> use Playwriter
- Need parallel isolated sessions -> use Playwright direct
- Natural language automation -> use Stagehand

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Complete setup (installs Bun if needed, clones repo, installs deps)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup

# Start server (reuses existing browser profile - stays logged in!)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start

# Start with fresh profile (no cookies, clean slate)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start-clean

# Check status (shows profile info)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh status

# View profile details
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh profile

# Reset profile (delete all browser data)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh reset-profile

# Stop server
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh stop
```

## Usage Pattern

### 1. Start Server First

The server must be running before executing scripts:

```bash
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start
# Or for headless mode:
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start-headless
```

### 2. Execute Scripts Inline

Scripts are executed via `bun x tsx` with heredoc:

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("main");

await page.goto("http://localhost:3000");
await waitForPageLoad(page);

console.log({ title: await page.title(), url: page.url() });
await client.disconnect();
EOF
```

### 3. Key Principles

1. **Small scripts**: Each script does ONE thing
2. **Evaluate state**: Always log state at the end
3. **Use page names**: `"main"`, `"checkout"`, `"login"` - pages persist by name
4. **Disconnect to exit**: `await client.disconnect()` at the end
5. **Plain JS in evaluate**: No TypeScript inside `page.evaluate()`

## Element Discovery

### ARIA Snapshot (Unknown Pages)

When you don't know the page structure, get an ARIA snapshot:

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("main");

await page.goto("https://example.com");
await waitForPageLoad(page);

const snapshot = await client.getAISnapshot("main");
console.log(snapshot);

await client.disconnect();
EOF
```

The snapshot returns elements with refs like `e1`, `e2`, etc.

### Interact with Refs

Use refs from the snapshot to interact:

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("main");

// Click element by ref from snapshot
const element = await client.selectSnapshotRef("main", "e5");
await element.click();
await waitForPageLoad(page);

await client.disconnect();
EOF
```

### Use Source Code Selectors

When you have access to the source code, use selectors directly:

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("main");

// Use selectors from source code
await page.click('[data-testid="submit-button"]');
await page.fill('input[name="email"]', 'test@example.com');

await client.disconnect();
EOF
```

## Common Operations

### Navigate and Screenshot

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("main");

await page.goto("http://localhost:3000/dashboard");
await waitForPageLoad(page);

await page.screenshot({ path: "tmp/dashboard.png" });
await page.screenshot({ path: "tmp/full.png", fullPage: true });

console.log("Screenshots saved to tmp/");
await client.disconnect();
EOF
```

### Fill Form and Submit

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("main");

await page.fill('input[name="username"]', 'testuser');
await page.fill('input[name="password"]', 'testpass');
await page.click('button[type="submit"]');

await waitForPageLoad(page);
console.log({ url: page.url(), title: await page.title() });

await client.disconnect();
EOF
```

### Extract Data

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("main");

// Extract text content
const heading = await page.textContent('h1');
const items = await page.$$eval('.item', els => els.map(e => e.textContent));

console.log({ heading, items });
await client.disconnect();
EOF
```

### Multi-Page Workflow

Pages persist by name, enabling multi-step workflows:

```bash
# Step 1: Login
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("app");  // Named "app"

await page.goto("http://localhost:3000/login");
await page.fill('input[name="email"]', 'user@example.com');
await page.fill('input[name="password"]', 'password');
await page.click('button[type="submit"]');
await waitForPageLoad(page);

console.log("Logged in:", page.url());
await client.disconnect();
EOF

# Step 2: Navigate (same page persists!)
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("app");  // Same "app" page, still logged in!

await page.goto("http://localhost:3000/settings");
await waitForPageLoad(page);

console.log("Settings page:", await page.title());
await client.disconnect();
EOF
```

## Custom Browser Engine (Brave, Edge, Chrome)

Dev-browser uses Playwright's bundled Chromium by default. To use a custom browser, you need to modify the server's launch configuration to pass `executablePath` to Playwright.

### Modifying the Server Launch

The dev-browser server script launches Playwright internally. To use a custom browser, set the `BROWSER_EXECUTABLE` environment variable before starting:

```bash
# Use Brave (built-in Shields for ad/tracker blocking)
BROWSER_EXECUTABLE="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start

# Use Edge (enterprise SSO, Azure AD)
BROWSER_EXECUTABLE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start

# Use Chrome
BROWSER_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start
```

**Note**: Custom browser support depends on the dev-browser server accepting `executablePath` in its Playwright launch options. If the server doesn't expose this, use Playwright direct with `launchPersistentContext` for the same persistent profile behaviour with a custom browser.

### Installing Extensions (uBlock Origin)

1. Start dev-browser in **headed mode**: `dev-browser-helper.sh start` (not `start-headless`)
2. Navigate to the Chrome Web Store in the browser
3. Install uBlock Origin (or any extension)
4. The extension persists in the profile directory across restarts

**Alternative**: Use Brave browser instead - Brave Shields provides equivalent ad/tracker blocking without needing uBlock Origin.

## Comparison with Other Browser Tools

| Feature | Dev-Browser | Playwriter | Playwright MCP | Stagehand |
|---------|-------------|------------|----------------|-----------|
| **State** | Persistent | Per-tab | Fresh each call | Fresh |
| **Speed** | Fast (batched) | Medium | Slow (round-trips) | Medium |
| **Context** | Low | Minimal | High (17+ tools) | Low |
| **Approach** | Scripts | Single tool | Tool calls | Natural language |
| **Best for** | Dev testing | Existing sessions | Cross-browser | AI automation |
| **Requires** | Bun + server | Chrome extension | Nothing | API key |

## Troubleshooting

### Server Not Running

```bash
# Check if server is running
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh status

# Start server
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start
```

### Port 9222 In Use

```bash
# Find process using port
lsof -i :9222

# Kill if needed
kill $(lsof -t -i :9222)

# Restart server
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh restart
```

### Script Errors

```bash
# Debug with screenshot
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("main");
await page.screenshot({ path: "tmp/debug.png" });
console.log({ url: page.url(), title: await page.title() });
await client.disconnect();
EOF
```

### Bun Not Found

```bash
# Install Bun
curl -fsSL https://bun.sh/install | bash

# Reload shell
source ~/.bashrc  # or ~/.zshrc
```

## Resources

- **GitHub**: https://github.com/SawyerHood/dev-browser
- **Benchmarks**: 14% faster, 39% cheaper, 43% fewer turns than Playwright MCP
- **License**: MIT
