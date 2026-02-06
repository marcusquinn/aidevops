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

**Parallel**: `--session s1/s2/s3` for isolated sessions (tested: 3 parallel in 2.0s). Each session has its own browser context.

**AI Page Understanding**: `agent-browser snapshot -i` returns ARIA tree with interactive refs. Use refs (`@e1`, `@e2`) for deterministic element targeting. Faster than screenshots for AI decision-making.

**iOS Support** (macOS only): Control real Mobile Safari in iOS Simulator via Appium. Use `-p ios --device "iPhone 16 Pro"` for mobile web testing.

**Limitations**: No proxy support, no browser extensions, no Chrome DevTools MCP pairing.

<!-- AI-CONTEXT-END -->

## Installation

### npm (recommended)

```bash
npm install -g agent-browser
agent-browser install  # Download Chromium
```

### Linux Dependencies

```bash
agent-browser install --with-deps
# or manually: npx playwright install-deps chromium
```

### From Source

```bash
git clone https://github.com/vercel-labs/agent-browser
cd agent-browser
pnpm install
pnpm build
agent-browser install
```

### iOS Simulator (macOS only)

Control real Mobile Safari in the iOS Simulator for authentic mobile web testing.

**Requirements:**

- macOS with Xcode installed
- Appium and XCUITest driver

```bash
# Install Appium and XCUITest driver
npm install -g appium
appium driver install xcuitest
```

## AI-Optimized Workflow

### The Snapshot + Ref Pattern

This is the **recommended workflow for AI agents**:

```bash
# 1. Navigate and get snapshot
agent-browser open example.com
agent-browser snapshot -i --json   # AI parses tree and refs

# 2. AI identifies target refs from snapshot
# Output includes refs like:
# - heading "Example Domain" [ref=e1] [level=1]
# - button "Submit" [ref=e2]
# - textbox "Email" [ref=e3]

# 3. Execute actions using refs
agent-browser click @e2
agent-browser fill @e3 "input text"

# 4. Get new snapshot if page changed
agent-browser snapshot -i --json
```

**Why use refs?**
- **Deterministic**: Ref points to exact element from snapshot
- **Fast**: No DOM re-query needed
- **AI-friendly**: Snapshot + ref workflow is optimal for LLMs

### Snapshot Options

```bash
agent-browser snapshot                    # Full accessibility tree
agent-browser snapshot -i                 # Interactive elements only
agent-browser snapshot -c                 # Compact (remove empty structural)
agent-browser snapshot -d 3               # Limit depth to 3 levels
agent-browser snapshot -s "#main"         # Scope to CSS selector
agent-browser snapshot -i -c -d 5         # Combine options
```

| Option | Description |
|--------|-------------|
| `-i, --interactive` | Only show interactive elements (buttons, links, inputs) |
| `-c, --compact` | Remove empty structural elements |
| `-d, --depth <n>` | Limit tree depth |
| `-s, --selector <sel>` | Scope to CSS selector |

## Core Commands

### Navigation

```bash
agent-browser open <url>              # Navigate to URL
agent-browser back                    # Go back
agent-browser forward                 # Go forward
agent-browser reload                  # Reload page
```

### Interaction

```bash
agent-browser click <sel>             # Click element
agent-browser dblclick <sel>          # Double-click element
agent-browser focus <sel>             # Focus element
agent-browser type <sel> <text>       # Type into element
agent-browser fill <sel> <text>       # Clear and fill
agent-browser press <key>             # Press key (Enter, Tab, Control+a)
agent-browser hover <sel>             # Hover element
agent-browser select <sel> <val>      # Select dropdown option
agent-browser check <sel>             # Check checkbox
agent-browser uncheck <sel>           # Uncheck checkbox
agent-browser scroll <dir> [px]       # Scroll (up/down/left/right)
agent-browser scrollintoview <sel>    # Scroll element into view
agent-browser drag <src> <tgt>        # Drag and drop
agent-browser upload <sel> <files>    # Upload files
```

### Get Info

```bash
agent-browser get text <sel>          # Get text content
agent-browser get html <sel>          # Get innerHTML
agent-browser get value <sel>         # Get input value
agent-browser get attr <sel> <attr>   # Get attribute
agent-browser get title               # Get page title
agent-browser get url                 # Get current URL
agent-browser get count <sel>         # Count matching elements
agent-browser get box <sel>           # Get bounding box
```

### Check State

```bash
agent-browser is visible <sel>        # Check if visible
agent-browser is enabled <sel>        # Check if enabled
agent-browser is checked <sel>        # Check if checked
```

### Screenshots & Output

```bash
agent-browser screenshot [path]       # Take screenshot (--full for full page)
agent-browser pdf <path>              # Save as PDF
agent-browser snapshot                # Accessibility tree with refs
agent-browser eval <js>               # Run JavaScript
agent-browser close                   # Close browser
```

## Selectors

### Refs (Recommended for AI)

```bash
# From snapshot output:
# - button "Submit" [ref=e2]
# - textbox "Email" [ref=e3]

agent-browser click @e2                   # Click the button
agent-browser fill @e3 "test@example.com" # Fill the textbox
```

### CSS Selectors

```bash
agent-browser click "#id"
agent-browser click ".class"
agent-browser click "div > button"
```

### Text & XPath

```bash
agent-browser click "text=Submit"
agent-browser click "xpath=//button"
```

### Semantic Locators

```bash
agent-browser find role button click --name "Submit"
agent-browser find text "Sign In" click
agent-browser find label "Email" fill "test@test.com"
agent-browser find first ".item" click
agent-browser find nth 2 "a" text
```

**Actions**: `click`, `fill`, `check`, `hover`, `text`

## Sessions

Run multiple isolated browser instances:

```bash
# Different sessions
agent-browser --session agent1 open site-a.com
agent-browser --session agent2 open site-b.com

# Or via environment variable
AGENT_BROWSER_SESSION=agent1 agent-browser click "#btn"

# List active sessions
agent-browser session list

# Show current session
agent-browser session
```

Each session has its own:
- Browser instance
- Cookies and storage
- Navigation history
- Authentication state

## Wait Commands

```bash
agent-browser wait <selector>         # Wait for element
agent-browser wait <ms>               # Wait for time
agent-browser wait --text "Welcome"   # Wait for text
agent-browser wait --url "**/dash"    # Wait for URL pattern
agent-browser wait --load networkidle # Wait for load state
agent-browser wait --fn "window.ready === true"  # Wait for JS condition
```

**Load states**: `load`, `domcontentloaded`, `networkidle`

## Cookies & Storage

```bash
agent-browser cookies                 # Get all cookies
agent-browser cookies set <name> <val> # Set cookie
agent-browser cookies clear           # Clear cookies

agent-browser storage local           # Get all localStorage
agent-browser storage local <key>     # Get specific key
agent-browser storage local set <k> <v>  # Set value
agent-browser storage local clear     # Clear all

agent-browser storage session         # Same for sessionStorage
```

## Network

```bash
agent-browser network route <url>              # Intercept requests
agent-browser network route <url> --abort      # Block requests
agent-browser network route <url> --body <json>  # Mock response
agent-browser network unroute [url]            # Remove routes
agent-browser network requests                 # View tracked requests
agent-browser network requests --filter api    # Filter requests
```

## Tabs & Windows

```bash
agent-browser tab                     # List tabs
agent-browser tab new [url]           # New tab (optionally with URL)
agent-browser tab <n>                 # Switch to tab n
agent-browser tab close [n]           # Close tab
agent-browser window new              # New window
```

## Frames

```bash
agent-browser frame <sel>             # Switch to iframe
agent-browser frame main              # Back to main frame
```

## Dialogs

```bash
agent-browser dialog accept [text]    # Accept (with optional prompt text)
agent-browser dialog dismiss          # Dismiss
```

## Debug

```bash
agent-browser trace start [path]      # Start recording trace
agent-browser trace stop [path]       # Stop and save trace
agent-browser console                 # View console messages
agent-browser console --clear         # Clear console
agent-browser errors                  # View page errors
agent-browser errors --clear          # Clear errors
agent-browser highlight <sel>         # Highlight element
agent-browser state save <path>       # Save auth state
agent-browser state load <path>       # Load auth state
```

## Browser Settings

```bash
agent-browser set viewport <w> <h>    # Set viewport size
agent-browser set device <name>       # Emulate device ("iPhone 14")
agent-browser set geo <lat> <lng>     # Set geolocation
agent-browser set offline [on|off]    # Toggle offline mode
agent-browser set headers <json>      # Extra HTTP headers
agent-browser set credentials <u> <p> # HTTP basic auth
agent-browser set media [dark|light]  # Emulate color scheme
```

## Mouse Control

```bash
agent-browser mouse move <x> <y>      # Move mouse
agent-browser mouse down [button]     # Press button (left/right/middle)
agent-browser mouse up [button]       # Release button
agent-browser mouse wheel <dy> [dx]   # Scroll wheel
```

## iOS Simulator

Control real Mobile Safari in the iOS Simulator for authentic mobile web testing. Requires macOS with Xcode.

### Setup

```bash
# Install Appium and XCUITest driver
npm install -g appium
appium driver install xcuitest
```

### Usage

```bash
# List available iOS simulators
agent-browser device list

# Launch Safari on a specific device
agent-browser -p ios --device "iPhone 16 Pro" open https://example.com

# Same commands as desktop
agent-browser -p ios snapshot -i
agent-browser -p ios tap @e1              # Tap (alias for click)
agent-browser -p ios fill @e2 "text"
agent-browser -p ios screenshot mobile.png

# Mobile-specific commands
agent-browser -p ios swipe up
agent-browser -p ios swipe down 500
agent-browser -p ios swipe left
agent-browser -p ios swipe right

# Close session (shuts down simulator)
agent-browser -p ios close
```

### Environment Variables

```bash
export AGENT_BROWSER_PROVIDER=ios
export AGENT_BROWSER_IOS_DEVICE="iPhone 16 Pro"
agent-browser open https://example.com
```

| Variable | Description |
|----------|-------------|
| `AGENT_BROWSER_PROVIDER` | Set to `ios` to enable iOS mode |
| `AGENT_BROWSER_IOS_DEVICE` | Device name (e.g., "iPhone 16 Pro", "iPad Pro") |
| `AGENT_BROWSER_IOS_UDID` | Device UDID (alternative to device name) |

**Supported devices:** All iOS Simulators available in Xcode (iPhones, iPads), plus real iOS devices.

**Note:** The iOS provider boots the simulator, starts Appium, and controls Safari. First launch takes ~30-60 seconds; subsequent commands are fast.

### Real Device Support

Appium also supports real iOS devices connected via USB. This requires additional one-time setup:

**1. Get your device UDID:**

```bash
xcrun xctrace list devices
# or
system_profiler SPUSBDataType | grep -A 5 "iPhone\|iPad"
```

**2. Sign WebDriverAgent (one-time):**

```bash
# Open the WebDriverAgent Xcode project
cd ~/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent
open WebDriverAgent.xcodeproj
```

In Xcode:

- Select the `WebDriverAgentRunner` target
- Go to Signing & Capabilities
- Select your Team (requires Apple Developer account, free tier works)
- Let Xcode manage signing automatically

**3. Use with agent-browser:**

```bash
# Connect device via USB, then:
agent-browser -p ios --device "<DEVICE_UDID>" open https://example.com

# Or use the device name if unique
agent-browser -p ios --device "John's iPhone" open https://example.com
```

**Real device notes:**

- First run installs WebDriverAgent to the device (may require Trust prompt)
- Device must be unlocked and connected via USB
- Slightly slower initial connection than simulator
- Tests against real Safari performance and behavior

## Agent Mode (JSON Output)

Use `--json` for machine-readable output:

```bash
agent-browser snapshot --json
# Returns: {"success":true,"data":{"snapshot":"...","refs":{"e1":{"role":"heading","name":"Title"},...}}}

agent-browser get text @e1 --json
agent-browser is visible @e2 --json
```

## Headed Mode

Show the browser window for debugging:

```bash
agent-browser open example.com --headed
```

## Architecture

agent-browser uses a client-daemon architecture:

1. **Rust CLI** (fast native binary) - Parses commands, communicates with daemon
2. **Node.js Daemon** - Manages Playwright browser instance
3. **Fallback** - If native binary unavailable, uses Node.js directly

The daemon starts automatically on first command and persists between commands for fast subsequent operations.

## Platform Support

| Platform | Binary | Fallback | iOS Support |
|----------|--------|----------|-------------|
| macOS ARM64 | Native Rust | Node.js | Yes (Simulator + Real) |
| macOS x64 | Native Rust | Node.js | Yes (Simulator + Real) |
| Linux ARM64 | Native Rust | Node.js | No |
| Linux x64 | Native Rust | Node.js | No |
| Windows | - | Node.js | No |

## Comparison with Other Tools

| Feature | agent-browser | dev-browser | Playwriter | Stagehand |
|---------|---------------|-------------|------------|-----------|
| Interface | CLI | TypeScript API | MCP | SDK |
| Selection | Refs + CSS | CSS + ARIA | Playwright API | Natural language |
| Sessions | Built-in | Manual | Extension tabs | Per-instance |
| AI-optimized | Snapshot + refs | ARIA snapshots | Execute tool | act/extract |
| Architecture | Rust + Node daemon | Bun + Playwright | Chrome extension | Browserbase |

### When to Use agent-browser

- **CLI-first workflows** - Shell scripts, CI/CD pipelines
- **Multi-session automation** - Parallel browser instances
- **AI agent integration** - Snapshot + ref pattern for LLMs
- **Cross-platform** - Native binaries for all major platforms

### When to Use Other Tools

- **dev-browser** - TypeScript/JavaScript projects, stateful pages
- **Playwriter** - Existing browser sessions, bypass detection
- **Stagehand** - Natural language automation, self-healing selectors
- **Crawl4AI** - Web scraping and content extraction

## Common Patterns

### Login Flow

```bash
agent-browser open https://app.example.com/login
agent-browser snapshot -i
# Identify refs from snapshot
agent-browser fill @e3 "user@example.com"
agent-browser fill @e4 "password"
agent-browser click @e5
agent-browser wait --url "**/dashboard"
agent-browser state save auth.json
```

### Form Submission

```bash
agent-browser open https://example.com/form
agent-browser snapshot -i
agent-browser fill @e1 "John Doe"
agent-browser fill @e2 "john@example.com"
agent-browser select @e3 "US"
agent-browser check @e4
agent-browser click @e5
agent-browser wait --text "Success"
```

### Data Extraction

```bash
agent-browser open https://example.com/products
agent-browser snapshot --json > products.json
# Parse JSON to extract product data
```

### Multi-Session Parallel

```bash
# Session 1: Login to site A
agent-browser --session s1 open https://site-a.com
agent-browser --session s1 state load auth-a.json

# Session 2: Login to site B
agent-browser --session s2 open https://site-b.com
agent-browser --session s2 state load auth-b.json

# Work in parallel
agent-browser --session s1 snapshot -i
agent-browser --session s2 snapshot -i
```

### iOS Mobile Testing

```bash
# List available simulators
agent-browser device list

# Open site on iPhone
agent-browser -p ios --device "iPhone 16 Pro" open https://example.com/mobile

# Same workflow as desktop
agent-browser -p ios snapshot -i
agent-browser -p ios tap @e1
agent-browser -p ios fill @e2 "user@example.com"

# Mobile-specific gestures
agent-browser -p ios swipe up
agent-browser -p ios swipe down 300

# Take mobile screenshot
agent-browser -p ios screenshot mobile-test.png

# Close (shuts down simulator)
agent-browser -p ios close
```

## Resources

- **GitHub**: https://github.com/vercel-labs/agent-browser
- **License**: Apache-2.0
- **Languages**: TypeScript (74%), Rust (22%)
