---
description: Agent Browser - headless browser automation CLI for AI agents with Rust CLI and Node.js fallback
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

# Agent Browser - Headless Browser Automation CLI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Headless browser automation CLI optimized for AI agents
- **Install**: `npm install -g agent-browser && agent-browser install`
- **Architecture**: Fast Rust CLI with Node.js fallback, Playwright-based daemon
- **GitHub**: https://github.com/vercel-labs/agent-browser

**Core Workflow** (optimal for AI):

```bash
agent-browser open example.com
agent-browser snapshot                    # Get accessibility tree with refs
agent-browser click @e2                   # Click by ref from snapshot
agent-browser fill @e3 "test@example.com" # Fill by ref
agent-browser get text @e1                # Get text by ref
agent-browser screenshot page.png
agent-browser close
```

**Key Advantages**:
- **Ref-based selection**: Deterministic element targeting from snapshots
- **AI-optimized**: `--json` output for machine parsing
- **Session isolation**: Multiple browser instances with `--session`
- **No server needed**: Daemon starts automatically, persists between commands
- **Headless by default**: Use `--headed` only for visual debugging

**Performance** (warm daemon): Navigate+screenshot 1.9s, form fill 1.4s, reliability 0.6s avg.
Cold-start penalty ~3-5s on first command while daemon launches.

**Parallel**: `--session s1/s2/s3` for isolated sessions (tested: 3 parallel in 2.0s).

**AI Page Understanding**: `agent-browser snapshot -i` returns ARIA tree with interactive refs. Use refs (`@e1`, `@e2`) for deterministic element targeting. Faster than screenshots for AI decision-making.

**iOS Support** (macOS only): Control real Mobile Safari in iOS Simulator via Appium. Use `-p ios --device "iPhone 16 Pro"` for mobile web testing.

**Limitations**: No proxy support, no browser extensions, no Chrome DevTools MCP pairing.

<!-- AI-CONTEXT-END -->

## Installation

```bash
npm install -g agent-browser
agent-browser install  # Download Chromium

# Linux: add --with-deps for system dependencies
agent-browser install --with-deps

# From source
git clone https://github.com/vercel-labs/agent-browser && cd agent-browser
pnpm install && pnpm build && agent-browser install
```

### iOS Simulator (macOS only)

```bash
npm install -g appium
appium driver install xcuitest
```

## AI-Optimized Workflow

### The Snapshot + Ref Pattern

```bash
agent-browser open example.com
agent-browser snapshot -i --json   # Returns refs: heading [ref=e1], button [ref=e2], textbox [ref=e3]
agent-browser click @e2
agent-browser fill @e3 "input text"
agent-browser snapshot -i --json   # Re-snapshot after page change
```

### Snapshot Options

```bash
agent-browser snapshot                    # Full accessibility tree
agent-browser snapshot -i                 # Interactive elements only
agent-browser snapshot -c                 # Compact (remove empty structural)
agent-browser snapshot -d 3               # Limit depth to 3 levels
agent-browser snapshot -s "#main"         # Scope to CSS selector
agent-browser snapshot -i -c -d 5         # Combine options
```

## Core Commands

### Navigation

```bash
agent-browser open <url>              # Navigate to URL
agent-browser back / forward / reload
```

### Interaction

```bash
agent-browser click <sel>             # Click element
agent-browser dblclick <sel>          # Double-click
agent-browser fill <sel> <text>       # Clear and fill
agent-browser type <sel> <text>       # Type into element
agent-browser press <key>             # Press key (Enter, Tab, Control+a)
agent-browser hover <sel>             # Hover element
agent-browser select <sel> <val>      # Select dropdown option
agent-browser check/uncheck <sel>     # Toggle checkbox
agent-browser scroll <dir> [px]       # Scroll (up/down/left/right)
agent-browser drag <src> <tgt>        # Drag and drop
agent-browser upload <sel> <files>    # Upload files
```

### Get Info

```bash
agent-browser get text <sel>          # Get text content
agent-browser get html <sel>          # Get innerHTML
agent-browser get value <sel>         # Get input value
agent-browser get attr <sel> <attr>   # Get attribute
agent-browser get title / url / count <sel> / box <sel>
agent-browser is visible/enabled/checked <sel>
```

### Screenshots & Output

```bash
agent-browser screenshot [path]       # Take screenshot (--full for full page)
agent-browser pdf <path>              # Save as PDF
agent-browser eval <js>               # Run JavaScript
agent-browser close                   # Close browser
```

## Selectors

```bash
# Refs (recommended — from snapshot output)
agent-browser click @e2
agent-browser fill @e3 "test@example.com"

# CSS
agent-browser click "#id" / ".class" / "div > button"

# Text / XPath
agent-browser click "text=Submit"
agent-browser click "xpath=//button"

# Semantic locators
agent-browser find role button click --name "Submit"
agent-browser find text "Sign In" click
agent-browser find label "Email" fill "test@test.com"
agent-browser find first ".item" click
agent-browser find nth 2 "a" text
```

## Sessions

```bash
agent-browser --session agent1 open site-a.com
agent-browser --session agent2 open site-b.com
AGENT_BROWSER_SESSION=agent1 agent-browser click "#btn"
agent-browser session list
```

Each session has its own browser instance, cookies, storage, history, and auth state.

## Wait Commands

```bash
agent-browser wait <selector>         # Wait for element
agent-browser wait <ms>               # Wait for time
agent-browser wait --text "Welcome"   # Wait for text
agent-browser wait --url "**/dash"    # Wait for URL pattern
agent-browser wait --load networkidle # Wait for load state (load/domcontentloaded/networkidle)
agent-browser wait --fn "window.ready === true"  # Wait for JS condition
```

## Cookies & Storage

```bash
agent-browser cookies / cookies set <name> <val> / cookies clear
agent-browser storage local [key] / storage local set <k> <v> / storage local clear
agent-browser storage session         # Same for sessionStorage
```

## Network

```bash
agent-browser network route <url>              # Intercept requests
agent-browser network route <url> --abort      # Block requests
agent-browser network route <url> --body <json>  # Mock response
agent-browser network unroute [url]
agent-browser network requests [--filter api]
```

## Tabs, Frames & Dialogs

```bash
agent-browser tab / tab new [url] / tab <n> / tab close [n]
agent-browser window new
agent-browser frame <sel> / frame main
agent-browser dialog accept [text] / dialog dismiss
```

## Debug & Settings

```bash
agent-browser trace start/stop [path]
agent-browser console [--clear] / errors [--clear]
agent-browser highlight <sel>
agent-browser state save/load <path>

agent-browser set viewport <w> <h>    # Set viewport size
agent-browser set device <name>       # Emulate device ("iPhone 14")
agent-browser set geo <lat> <lng>     # Set geolocation
agent-browser set offline [on|off]    # Toggle offline mode
agent-browser set headers <json>      # Extra HTTP headers
agent-browser set credentials <u> <p> # HTTP basic auth
agent-browser set media [dark|light]  # Emulate color scheme

agent-browser mouse move <x> <y> / mouse down/up [button] / mouse wheel <dy> [dx]
```

## iOS Simulator

```bash
agent-browser device list
agent-browser -p ios --device "iPhone 16 Pro" open https://example.com
agent-browser -p ios snapshot -i
agent-browser -p ios tap @e1              # Tap (alias for click)
agent-browser -p ios fill @e2 "text"
agent-browser -p ios swipe up/down/left/right [px]
agent-browser -p ios screenshot mobile.png
agent-browser -p ios close
```

**Env vars**: `AGENT_BROWSER_PROVIDER=ios`, `AGENT_BROWSER_IOS_DEVICE="iPhone 16 Pro"`, `AGENT_BROWSER_IOS_UDID=<udid>`

First launch ~30-60s (boots simulator + Appium); subsequent commands are fast.

**Real device**: Connect via USB, sign WebDriverAgent in Xcode (one-time), then use `--device "<UDID>"`. Device must be unlocked.

## Agent Mode (JSON Output)

```bash
agent-browser snapshot --json
# Returns: {"success":true,"data":{"snapshot":"...","refs":{"e1":{"role":"heading","name":"Title"},...}}}
agent-browser get text @e1 --json
agent-browser is visible @e2 --json
```

## Common Patterns

### Login Flow

```bash
agent-browser open https://app.example.com/login
agent-browser snapshot -i
agent-browser fill @e3 "user@example.com"
agent-browser fill @e4 "password"
agent-browser click @e5
agent-browser wait --url "**/dashboard"
agent-browser state save auth.json
```

### Multi-Session Parallel

```bash
agent-browser --session s1 open https://site-a.com && agent-browser --session s1 state load auth-a.json
agent-browser --session s2 open https://site-b.com && agent-browser --session s2 state load auth-b.json
agent-browser --session s1 snapshot -i
agent-browser --session s2 snapshot -i
```

### Data Extraction

```bash
agent-browser open https://example.com/products
agent-browser snapshot --json > products.json
```

## Architecture

Client-daemon architecture: **Rust CLI** (fast native binary) → **Node.js Daemon** (manages Playwright). Daemon starts automatically on first command and persists for fast subsequent operations. Falls back to Node.js if native binary unavailable.

## Platform Support

| Platform | Binary | Fallback | iOS Support |
|----------|--------|----------|-------------|
| macOS ARM64/x64 | Native Rust | Node.js | Yes (Simulator + Real) |
| Linux ARM64/x64 | Native Rust | Node.js | No |
| Windows | - | Node.js | No |

## Comparison with Other Tools

| Feature | agent-browser | dev-browser | Playwriter | Stagehand |
|---------|---------------|-------------|------------|-----------|
| Interface | CLI | TypeScript API | MCP | SDK |
| Selection | Refs + CSS | CSS + ARIA | Playwright API | Natural language |
| Sessions | Built-in | Manual | Extension tabs | Per-instance |
| AI-optimized | Snapshot + refs | ARIA snapshots | Execute tool | act/extract |
| Architecture | Rust + Node daemon | Bun + Playwright | Chrome extension | Browserbase |

- **dev-browser**: TypeScript/JavaScript projects, stateful pages
- **Playwriter**: Existing browser sessions, bypass detection
- **Stagehand**: Natural language automation, self-healing selectors
- **Crawl4AI**: Web scraping and content extraction

## Resources

- **GitHub**: https://github.com/vercel-labs/agent-browser
- **License**: Apache-2.0
- **Languages**: TypeScript (74%), Rust (22%)
