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

**Performance** (warm daemon): Navigate+screenshot 1.9s, form fill 1.4s, reliability 0.6s avg. Cold-start ~3-5s on first command.

**Parallel**: `--session s1/s2/s3` for isolated sessions (3 parallel tested in 2.0s).

**AI Page Understanding**: `agent-browser snapshot -i` returns ARIA tree with interactive refs. Use refs (`@e1`, `@e2`) for deterministic targeting — faster than screenshots for AI decision-making.

**iOS Support** (macOS only): Control real Mobile Safari in iOS Simulator via Appium. Use `-p ios --device "iPhone 16 Pro"`.

**Limitations**: No proxy support, no browser extensions, no Chrome DevTools MCP pairing.

<!-- AI-CONTEXT-END -->

## Installation

```bash
npm install -g agent-browser
agent-browser install  # Download Chromium

# Linux dependencies
agent-browser install --with-deps

# From source
git clone https://github.com/vercel-labs/agent-browser && cd agent-browser
pnpm install && pnpm build && agent-browser install

# iOS Simulator (macOS only)
npm install -g appium && appium driver install xcuitest
```

## AI-Optimized Workflow: Snapshot + Ref Pattern

```bash
agent-browser open example.com
agent-browser snapshot -i --json   # Returns refs: heading "Example Domain" [ref=e1], button "Submit" [ref=e2]
agent-browser click @e2
agent-browser fill @e3 "input text"
agent-browser snapshot -i --json   # Re-snapshot after page change
```

**Why refs?** Deterministic (exact element from snapshot), fast (no DOM re-query), AI-friendly.

**Snapshot options**:

| Option | Description |
|--------|-------------|
| `-i, --interactive` | Only interactive elements (buttons, links, inputs) |
| `-c, --compact` | Remove empty structural elements |
| `-d, --depth <n>` | Limit tree depth |
| `-s, --selector <sel>` | Scope to CSS selector |

## Core Commands

```bash
# Navigation
agent-browser open <url> | back | forward | reload

# Interaction
agent-browser click <sel>             # Click element
agent-browser fill <sel> <text>       # Clear and fill
agent-browser type <sel> <text>       # Type into element
agent-browser press <key>             # Press key (Enter, Tab, Control+a)
agent-browser select <sel> <val>      # Select dropdown option
agent-browser check/uncheck <sel>     # Checkbox
agent-browser scroll <dir> [px]       # up/down/left/right
agent-browser drag <src> <tgt>        # Drag and drop
agent-browser upload <sel> <files>    # Upload files
agent-browser hover <sel>             # Hover

# Get Info
agent-browser get text/html/value/title/url <sel>
agent-browser get attr <sel> <attr>
agent-browser get count/box <sel>

# State checks
agent-browser is visible/enabled/checked <sel>

# Output
agent-browser screenshot [path] [--full]
agent-browser pdf <path>
agent-browser eval <js>
agent-browser close
```

## Selectors

```bash
# Refs (recommended for AI — from snapshot)
agent-browser click @e2
agent-browser fill @e3 "test@example.com"

# CSS
agent-browser click "#id" | ".class" | "div > button"

# Text / XPath
agent-browser click "text=Submit" | "xpath=//button"

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

## Wait, Cookies, Storage, Network

```bash
# Wait
agent-browser wait <selector> | <ms> | --text "Welcome" | --url "**/dash" | --load networkidle
agent-browser wait --fn "window.ready === true"

# Cookies
agent-browser cookies | cookies set <name> <val> | cookies clear

# Storage
agent-browser storage local [<key>] | storage local set <k> <v> | storage local clear
agent-browser storage session  # same for sessionStorage

# Network
agent-browser network route <url> [--abort | --body <json>]
agent-browser network unroute [url]
agent-browser network requests [--filter api]
```

## Tabs, Frames, Dialogs, Debug

```bash
# Tabs
agent-browser tab | tab new [url] | tab <n> | tab close [n]
agent-browser window new

# Frames
agent-browser frame <sel> | frame main

# Dialogs
agent-browser dialog accept [text] | dialog dismiss

# Debug
agent-browser trace start/stop [path]
agent-browser console [--clear] | errors [--clear]
agent-browser highlight <sel>
agent-browser state save/load <path>
```

## Browser Settings & Mouse

```bash
agent-browser set viewport <w> <h> | device <name> | geo <lat> <lng>
agent-browser set offline [on|off] | headers <json> | credentials <u> <p> | media [dark|light]

agent-browser mouse move <x> <y> | down/up [button] | wheel <dy> [dx]
```

## iOS Simulator

```bash
agent-browser device list
agent-browser -p ios --device "iPhone 16 Pro" open https://example.com
agent-browser -p ios snapshot -i
agent-browser -p ios tap @e1              # tap = alias for click
agent-browser -p ios swipe up/down/left/right [px]
agent-browser -p ios screenshot mobile.png
agent-browser -p ios close
```

**Env vars**: `AGENT_BROWSER_PROVIDER=ios`, `AGENT_BROWSER_IOS_DEVICE="iPhone 16 Pro"`, `AGENT_BROWSER_IOS_UDID=<udid>`

**First launch**: ~30-60s to boot simulator; subsequent commands are fast.

**Real device**: Get UDID via `xcrun xctrace list devices`, sign WebDriverAgent in Xcode (free Apple Developer account), then `agent-browser -p ios --device "<UDID>" open https://example.com`.

## Agent Mode & Headed Mode

```bash
agent-browser snapshot --json   # {"success":true,"data":{"snapshot":"...","refs":{...}}}
agent-browser get text @e1 --json
agent-browser is visible @e2 --json

agent-browser open example.com --headed  # Show browser window for debugging
```

## Platform Support

| Platform | Binary | Fallback | iOS |
|----------|--------|----------|-----|
| macOS ARM64/x64 | Native Rust | Node.js | Yes |
| Linux ARM64/x64 | Native Rust | Node.js | No |
| Windows | — | Node.js | No |

## Comparison with Other Tools

| Feature | agent-browser | dev-browser | Playwriter | Stagehand |
|---------|---------------|-------------|------------|-----------|
| Interface | CLI | TypeScript API | MCP | SDK |
| Selection | Refs + CSS | CSS + ARIA | Playwright API | Natural language |
| Sessions | Built-in | Manual | Extension tabs | Per-instance |
| Architecture | Rust + Node daemon | Bun + Playwright | Chrome extension | Browserbase |

**Use agent-browser for**: CLI-first workflows, multi-session automation, AI agent integration, cross-platform.
**Use others for**: dev-browser (TypeScript projects, stateful pages), Playwriter (existing sessions, bypass detection), Stagehand (natural language, self-healing), Crawl4AI (scraping).

## Common Patterns

```bash
# Login flow
agent-browser open https://app.example.com/login
agent-browser snapshot -i
agent-browser fill @e3 "user@example.com" && agent-browser fill @e4 "password"
agent-browser click @e5 && agent-browser wait --url "**/dashboard"
agent-browser state save auth.json

# Form submission
agent-browser open https://example.com/form && agent-browser snapshot -i
agent-browser fill @e1 "John Doe" && agent-browser fill @e2 "john@example.com"
agent-browser select @e3 "US" && agent-browser check @e4
agent-browser click @e5 && agent-browser wait --text "Success"

# Data extraction
agent-browser open https://example.com/products
agent-browser snapshot --json > products.json

# Multi-session parallel
agent-browser --session s1 open https://site-a.com && agent-browser --session s1 state load auth-a.json
agent-browser --session s2 open https://site-b.com && agent-browser --session s2 state load auth-b.json
```

## Resources

- **GitHub**: https://github.com/vercel-labs/agent-browser
- **License**: Apache-2.0
- **Languages**: TypeScript (74%), Rust (22%)
