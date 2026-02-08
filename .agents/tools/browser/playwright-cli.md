---
description: Playwright CLI - headless browser automation CLI designed for AI agents (Microsoft official)
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

# Playwright CLI - Browser Automation for AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Headless browser automation CLI designed specifically for AI agents
- **Install**: `npm install -g @playwright/mcp@latest`
- **GitHub**: https://github.com/microsoft/playwright-cli
- **Skill**: Available as Claude Code skill via `/plugin marketplace add microsoft/playwright-cli`

**Core Workflow** (optimal for AI):

```bash
playwright-cli open https://example.com
playwright-cli snapshot                    # Get accessibility tree with refs
playwright-cli click e2                    # Click by ref from snapshot
playwright-cli fill e3 "test@example.com"  # Fill by ref
playwright-cli type "search query"         # Type into focused element
playwright-cli screenshot
playwright-cli close
```

**Key Advantages**:

- **Microsoft official**: Part of `@playwright/mcp`, actively maintained
- **Ref-based selection**: Deterministic element targeting from snapshots (e1, e2, e3)
- **Session isolation**: `--session` flag for parallel browser instances
- **Headless by default**: Use `--headed` only for visual debugging
- **Persistent profiles**: Sessions preserve cookies/storage between calls
- **Tracing built-in**: `tracing-start/stop` for debugging
- **No MCP overhead**: Direct CLI calls, no WebSocket relay

**Performance**: Similar to agent-browser (both use Playwright engine). Navigate+screenshot ~1.9s, form fill ~1.4s.

**vs agent-browser**: playwright-cli uses simpler ref syntax (`e5` vs `@e5`), has built-in tracing, and is Microsoft-maintained. agent-browser has more CLI commands and a Rust binary (but slower cold start ~3-5s vs ~2s).

**vs Playwriter MCP**: playwright-cli runs headless with isolated sessions. Playwriter uses your existing browser (headed, with your extensions/passwords).

**When to use**:

- AI agent automation (forms, clicks, navigation)
- CI/CD pipelines and shell scripts
- Parallel browser sessions
- Tasks that don't need your existing browser state

<!-- AI-CONTEXT-END -->

## Installation

```bash
# Install globally (recommended - fastest, no runner overhead)
bun install -g @playwright/mcp@latest   # Bun (preferred)
npm install -g @playwright/mcp@latest   # npm alternative

# Verify installation
playwright-cli --help

# Or run without global install (slower cold start)
bunx @playwright/mcp playwright-cli --help   # ~0.3s
npx @playwright/mcp playwright-cli --help    # ~2-3s (registry lookup)
```

**As Claude Code skill** (recommended for Claude Code users):

```bash
/plugin marketplace add microsoft/playwright-cli
/plugin install playwright-cli
```

**Manual skill installation**:

```bash
mkdir -p .claude/skills/playwright-cli
curl -o .claude/skills/playwright-cli/SKILL.md \
  https://raw.githubusercontent.com/microsoft/playwright-cli/main/skills/playwright-cli/SKILL.md
```

## Core Workflow

### The Snapshot + Ref Pattern

This is the **recommended workflow for AI agents**:

```bash
# 1. Navigate and get snapshot
playwright-cli open https://example.com
playwright-cli snapshot

# 2. AI identifies target refs from snapshot
# Output includes refs like:
# - heading "Example Domain" [ref=e1] [level=1]
# - button "Submit" [ref=e2]
# - textbox "Email" [ref=e3]

# 3. Execute actions using refs
playwright-cli click e2
playwright-cli fill e3 "input text"

# 4. Get new snapshot if page changed
playwright-cli snapshot
```

**Why use refs?**

- **Deterministic**: Ref points to exact element from snapshot
- **Fast**: No DOM re-query needed
- **AI-friendly**: Snapshot + ref workflow is optimal for LLMs

## Commands Reference

### Core

```bash
playwright-cli open <url>               # Navigate to URL
playwright-cli close                    # Close the page
playwright-cli type <text>              # Type text into focused/editable element
playwright-cli click <ref> [button]     # Click element (left/right/middle)
playwright-cli dblclick <ref> [button]  # Double-click element
playwright-cli fill <ref> <text>        # Clear and fill input
playwright-cli drag <startRef> <endRef> # Drag and drop between elements
playwright-cli hover <ref>              # Hover over element
playwright-cli select <ref> <value>     # Select dropdown option
playwright-cli upload <file>            # Upload file(s)
playwright-cli check <ref>              # Check checkbox/radio
playwright-cli uncheck <ref>            # Uncheck checkbox
playwright-cli snapshot                 # Get accessibility tree with refs
playwright-cli eval <func> [ref]        # Evaluate JavaScript
playwright-cli dialog-accept [prompt]   # Accept dialog (with optional prompt text)
playwright-cli dialog-dismiss           # Dismiss dialog
playwright-cli resize <width> <height>  # Resize browser window
```

### Navigation

```bash
playwright-cli go-back                  # Navigate back
playwright-cli go-forward               # Navigate forward
playwright-cli reload                   # Reload page
```

### Keyboard

```bash
playwright-cli press <key>              # Press key (Enter, ArrowDown, Tab, etc.)
playwright-cli keydown <key>            # Press key down
playwright-cli keyup <key>              # Release key
```

### Mouse

```bash
playwright-cli mousemove <x> <y>        # Move mouse to position
playwright-cli mousedown [button]       # Press mouse button
playwright-cli mouseup [button]         # Release mouse button
playwright-cli mousewheel <dx> <dy>     # Scroll mouse wheel
```

### Save As

```bash
playwright-cli screenshot               # Screenshot current page
playwright-cli screenshot <ref>         # Screenshot specific element
playwright-cli pdf                      # Save page as PDF
```

### Tabs

```bash
playwright-cli tab-list                 # List all tabs
playwright-cli tab-new [url]            # Create new tab
playwright-cli tab-close [index]        # Close tab
playwright-cli tab-select <index>       # Switch to tab
```

### DevTools

```bash
playwright-cli console [min-level]      # List console messages
playwright-cli network                  # List network requests
playwright-cli run-code <code>          # Run Playwright code snippet
playwright-cli tracing-start            # Start trace recording
playwright-cli tracing-stop             # Stop trace recording
```

### Sessions

```bash
playwright-cli --session=name open <url>  # Use named session
playwright-cli session-list               # List all sessions
playwright-cli session-stop [name]        # Stop session
playwright-cli session-stop-all           # Stop all sessions
playwright-cli session-delete [name]      # Delete session data and profile
```

## Sessions

Playwright CLI uses persistent profiles by default. Cookies and storage are preserved between calls.

### Named Sessions

Run multiple isolated browser instances:

```bash
# Different sessions for different tasks
playwright-cli open https://playwright.dev
playwright-cli --session=example open https://example.com
playwright-cli session-list

# Work in specific session
playwright-cli --session=example click e4
playwright-cli --session=example snapshot
```

### Environment Variable

Set session via environment for all commands:

```bash
PLAYWRIGHT_CLI_SESSION=todo-app claude .
```

### Session Management

```bash
playwright-cli session-list             # List all sessions
playwright-cli session-stop [name]      # Stop session (keeps profile)
playwright-cli session-stop-all         # Stop all sessions
playwright-cli session-delete [name]    # Delete session + profile data
```

## Headed Mode

Show the browser window for debugging:

```bash
playwright-cli open https://playwright.dev --headed
```

## Examples

### Form Submission

```bash
playwright-cli open https://example.com/form
playwright-cli snapshot

playwright-cli fill e1 "user@example.com"
playwright-cli fill e2 "$PASSWORD"  # Store credentials in env var or secure vault
playwright-cli click e3
playwright-cli snapshot
```

### Multi-Tab Workflow

```bash
playwright-cli open https://example.com
playwright-cli tab-new https://example.com/other
playwright-cli tab-list
playwright-cli tab-select 0
playwright-cli snapshot
```

### Debugging with DevTools

```bash
playwright-cli open https://example.com
playwright-cli click e4
playwright-cli fill e7 "test"
playwright-cli console
playwright-cli network
```

### Tracing for Debug

```bash
playwright-cli open https://example.com
playwright-cli tracing-start
playwright-cli click e4
playwright-cli fill e7 "test"
playwright-cli tracing-stop
# Opens trace viewer with recorded actions
```

### Todo App Demo

```bash
playwright-cli open https://demo.playwright.dev/todomvc/ --headed
playwright-cli type "Buy groceries"
playwright-cli press Enter
playwright-cli type "Water flowers"
playwright-cli press Enter
playwright-cli snapshot                    # Get refs for the todo items
playwright-cli check e21                   # Check first todo (ref from snapshot)
playwright-cli check e35                   # Check second todo (ref from snapshot)
playwright-cli screenshot
```

## Comparison with Other Tools

| Feature | playwright-cli | agent-browser | Playwriter | Stagehand |
|---------|---------------|---------------|------------|-----------|
| **Maintainer** | Microsoft | Vercel | Community | Browserbase |
| **Interface** | CLI | CLI | MCP | SDK |
| **Ref syntax** | `e5` | `@e5` | aria-ref | Natural language |
| **Sessions** | `--session` | `--session` | Your browser | Per-instance |
| **Tracing** | Built-in | Via Playwright | Via CDP | Via Playwright |
| **Headless** | Default | Default | No (your browser) | Default |
| **Extensions** | No | No | Yes (yours) | Possible |
| **Cold start** | ~2s | ~3-5s (Rust) | ~1s (extension) | ~2s |

### When to Use playwright-cli

- **AI agent automation** - Snapshot + ref pattern for LLMs
- **CLI-first workflows** - Shell scripts, CI/CD pipelines
- **Multi-session automation** - Parallel browser instances
- **Microsoft ecosystem** - Official Playwright tooling

### When to Use Other Tools

- **agent-browser** - More CLI commands, Rust binary (but slower cold start)
- **Playwriter** - Need your existing browser sessions, extensions, passwords
- **Stagehand** - Natural language automation, self-healing selectors
- **Playwright direct** - Maximum speed, full API control, TypeScript projects

## Integration with Other Tools

### Chrome DevTools MCP

playwright-cli exposes a CDP endpoint that Chrome DevTools MCP can connect to for debugging:

```bash
# Start playwright-cli with remote debugging
playwright-cli open https://example.com --headed

# In another terminal, connect DevTools MCP to the browser
# (playwright-cli uses Chromium on port 9222 by default)
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
```

**Use cases**:
- Performance profiling with Lighthouse while automating
- Network monitoring during form submissions
- CSS coverage analysis
- Console error capture

See `tools/browser/chrome-devtools.md` for full DevTools capabilities.

### Anti-Detect Browser Stack

playwright-cli uses Playwright under the hood, so it works with the anti-detect stack:

**Quick stealth (rebrowser-patches)**:

```bash
# Install rebrowser-patches for Chromium
# See tools/browser/stealth-patches.md for setup

# playwright-cli will use the patched Chromium automatically
# if installed in the Playwright browsers directory
playwright-cli open https://bot-detection-test.com
```

**Full anti-detect (Camoufox)**:

For maximum stealth with fingerprint rotation, use Camoufox directly with Playwright API rather than playwright-cli. See `tools/browser/anti-detect-browser.md`.

| Stealth Level | Tool | Use Case |
|---------------|------|----------|
| None | playwright-cli (default) | Dev testing, trusted sites |
| Medium | rebrowser-patches + playwright-cli | Hide automation signals |
| High | Camoufox + Playwright API | Bot detection evasion, multi-account |

## Related

- `playwright.md` - Core Playwright automation (cross-browser, forms, security, API testing)
- `playwright-emulation.md` - Device emulation (mobile, tablet, viewport, geolocation, locale, dark mode)
- `browser-automation.md` - Tool selection decision tree

## Resources

- **GitHub**: https://github.com/microsoft/playwright-cli
- **Skill**: https://github.com/microsoft/playwright-cli/tree/main/skills/playwright-cli
- **License**: Apache-2.0
- **Part of**: `@playwright/mcp` package
