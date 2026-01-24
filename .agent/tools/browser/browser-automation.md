---
description: Browser automation tool selection and usage guide
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

# Browser Automation - Tool Selection Guide

<!-- AI-CONTEXT-START -->

## Default Tool: Agent-Browser

**ALWAYS use agent-browser first** for any browser automation task. It's CLI-first, AI-optimized, and requires no server setup.

```bash
# Setup (one-time)
~/.aidevops/agents/scripts/agent-browser-helper.sh setup

# Basic workflow
agent-browser open example.com
agent-browser snapshot -i              # Get interactive elements with refs
agent-browser click @e2                # Click by ref
agent-browser close
```

**Why agent-browser is default**:
- **Zero setup**: No daemon to start, just run commands
- **AI-optimized**: Snapshot + ref pattern for deterministic element targeting
- **Multi-session**: Isolated browser instances with `--session`
- **Visual debugging**: Screenshots and DevTools for self-diagnosis

## Visual Debugging (Don't Ask User - Check Yourself)

**CRITICAL**: Before asking the user what they see, use these tools to check yourself:

```bash
# Take screenshot to see current state
agent-browser screenshot /tmp/current-state.png

# Get page info
agent-browser get title
agent-browser get url

# Check for errors
agent-browser errors

# View console messages
agent-browser console

# Get element state
agent-browser is visible @e5
agent-browser is enabled @e5

# Headed mode for complex debugging
agent-browser open example.com --headed
```

**Self-diagnosis workflow**:
1. Action fails or unexpected result
2. Take screenshot: `agent-browser screenshot /tmp/debug.png`
3. Check errors: `agent-browser errors`
4. Get snapshot: `agent-browser snapshot -i`
5. Analyze and retry - only ask user if truly stuck

## Tool Selection Decision Tree

```text
Need browser automation?
    │
    ├─► Default choice ──► agent-browser (CLI-first, AI-optimized)
    │
    ├─► Need TypeScript API / stateful pages? ──► dev-browser
    │
    ├─► Need existing browser session/cookies? ──► Playwriter
    │
    ├─► Need cookies for API calls (no browser)? ──► sweet-cookie
    │
    ├─► Need natural language control? ──► Stagehand
    │
    └─► Need web crawling/extraction? ──► Crawl4AI
```

## Quick Reference

| Tool | Best For | Setup |
|------|----------|-------|
| **agent-browser** (DEFAULT) | CLI automation, AI agents, CI/CD, multi-session | `agent-browser-helper.sh setup` |
| **dev-browser** | TypeScript API, stateful pages, dev testing | `dev-browser-helper.sh setup` |
| **playwriter** | Existing sessions, bypass detection | Chrome extension + MCP |
| **sweet-cookie** | Cookie extraction for API calls, session reuse | `npm i @steipete/sweet-cookie` |
| **stagehand** | Natural language automation | `stagehand-helper.sh setup` |
| **crawl4ai** | Web scraping, content extraction | `crawl4ai-helper.sh setup` |
| **playwright** | Cross-browser testing | `setup.sh` or `npx playwright install` |

**Full docs**: `tools/browser/agent-browser.md` (default), `tools/browser/dev-browser.md`, `tools/browser/sweet-cookie.md`, etc.

**Ethical Rules**: Respect ToS, rate limit (2-5s delays), no spam, legitimate use only
<!-- AI-CONTEXT-END -->

## Session Persistence (Cookies, Storage, Auth State)

### Why Persist Sessions?

- **Avoid repeated logins**: Save auth state once, reuse across sessions
- **Maintain context**: Keep shopping carts, preferences, form data
- **Faster automation**: Skip login flows in subsequent runs

### Saving Auth State

After logging in, save the complete browser state:

```bash
# Login to a site
agent-browser open https://app.example.com/login
agent-browser snapshot -i
agent-browser fill @e3 "user@example.com"
agent-browser fill @e4 "password"
agent-browser click @e5
agent-browser wait --url "**/dashboard"

# Save auth state (cookies + localStorage + sessionStorage)
agent-browser state save ~/.aidevops/.agent-workspace/auth/example-com.json
agent-browser close
```

### Loading Auth State

Restore saved state in new sessions:

```bash
# Start new session with saved auth
agent-browser open https://app.example.com
agent-browser state load ~/.aidevops/.agent-workspace/auth/example-com.json
agent-browser reload  # Apply loaded state
# Now logged in without re-entering credentials
```

### Cookie Management

```bash
# View all cookies
agent-browser cookies

# Set a specific cookie
agent-browser cookies set "session_id" "abc123"

# Set cookie with options
agent-browser cookies set "auth_token" "xyz789" --domain ".example.com" --path "/" --secure

# Clear all cookies
agent-browser cookies clear
```

### LocalStorage & SessionStorage

```bash
# View all localStorage
agent-browser storage local

# Get specific key
agent-browser storage local "user_preferences"

# Set value
agent-browser storage local set "theme" "dark"
agent-browser storage local set "api_token" "bearer_xyz123"

# Clear localStorage
agent-browser storage local clear

# Same commands work for sessionStorage
agent-browser storage session
agent-browser storage session set "temp_data" "value"
agent-browser storage session clear
```

### Multi-Session with Shared Auth

```bash
# Session 1: Login and save state
agent-browser --session login open https://app.example.com/login
# ... perform login ...
agent-browser --session login state save ~/.aidevops/.agent-workspace/auth/app.json
agent-browser --session login close

# Session 2: Use saved auth for task A
agent-browser --session taskA open https://app.example.com
agent-browser --session taskA state load ~/.aidevops/.agent-workspace/auth/app.json
agent-browser --session taskA reload
# ... perform task A ...

# Session 3: Use same auth for task B (parallel)
agent-browser --session taskB open https://app.example.com
agent-browser --session taskB state load ~/.aidevops/.agent-workspace/auth/app.json
agent-browser --session taskB reload
# ... perform task B ...
```

### Auth State Best Practices

| Practice | Why |
|----------|-----|
| Store in `~/.aidevops/.agent-workspace/auth/` | Gitignored, secure location |
| Name by domain | `github-com.json`, `app-example-com.json` |
| Refresh periodically | Sessions expire, re-login and re-save |
| Don't commit auth files | Contains sensitive tokens |
| Use `--session` for isolation | Prevent cross-contamination |

### Injecting Cookies/Tokens Programmatically

For CI/CD or scripts where you have tokens from environment:

```bash
# Set auth cookie from environment variable
agent-browser open https://api.example.com
agent-browser cookies set "auth_token" "$AUTH_TOKEN" --domain ".example.com" --secure --httponly
agent-browser reload

# Or inject into localStorage
agent-browser storage local set "access_token" "$ACCESS_TOKEN"
agent-browser storage local set "refresh_token" "$REFRESH_TOKEN"
agent-browser reload
```

## Agent-Browser Usage (Default)

### Quick Start

```bash
# 1. Setup (one-time)
~/.aidevops/agents/scripts/agent-browser-helper.sh setup

# 2. Basic workflow
agent-browser open https://example.com
agent-browser snapshot -i                 # Interactive elements only
agent-browser click @e1                   # Click by ref
agent-browser screenshot page.png
agent-browser close
```

### Snapshot + Ref Pattern (AI-Optimized)

This is the **recommended workflow for AI agents**:

```bash
# 1. Navigate and get snapshot
agent-browser open https://news.ycombinator.com
agent-browser snapshot -i --json

# Output includes refs:
# - link "Hacker News" [ref=e2]
# - link "new" [ref=e3]
# - textbox [ref=e224]

# 2. Use refs for deterministic interaction
agent-browser click @e3                   # Click "new" link
agent-browser fill @e224 "search term"    # Fill search box

# 3. Get new snapshot after page change
agent-browser snapshot -i
```

### Common Patterns

**Form submission**:

```bash
agent-browser open https://example.com/contact
agent-browser snapshot -i
agent-browser fill @e1 "John Doe"
agent-browser fill @e2 "john@example.com"
agent-browser fill @e3 "Hello, this is my message"
agent-browser click @e4  # Submit button
agent-browser wait --text "Thank you"
agent-browser screenshot /tmp/success.png
```

**Multi-page workflow**:

```bash
agent-browser open https://shop.example.com
agent-browser snapshot -i
agent-browser click @e5  # Product link
agent-browser wait --load networkidle
agent-browser snapshot -i
agent-browser click @e3  # Add to cart
agent-browser click @e8  # Checkout
agent-browser state save ~/.aidevops/.agent-workspace/auth/shop-cart.json
```

**Full documentation**: `tools/browser/agent-browser.md`

## Alternative Tools

Use these when agent-browser doesn't fit the use case:

### Dev-Browser - TypeScript API

**Stateful browser automation with persistent Playwright server**

```bash
# Setup and start
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start

# Use TypeScript API
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

**When to use**: TypeScript projects, stateful page interactions, dev testing with hot reload.

See `tools/browser/dev-browser.md` for full documentation.

### Playwriter - Chrome Extension MCP

**Browser automation via Chrome extension with full Playwright API**

```bash
# 1. Install Chrome extension
# https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe

# 2. Add to MCP config (OpenCode)
# "playwriter": { "type": "local", "command": ["npx", "playwriter@latest"] }

# 3. Click extension icon on tabs to control (turns green)
```

**When to use**: Reuse existing browser sessions, bypass automation detection, work alongside AI with your extensions.

See `tools/browser/playwriter.md` for full documentation.

### Stagehand - Natural Language Automation

**AI-powered browser automation with natural language control**

```bash
# Setup
bash ~/.aidevops/agents/scripts/stagehand-helper.sh setup

# Natural language actions
await stagehand.act("click the login button")
await stagehand.act("fill in the email field with user@example.com")

# Structured extraction
const data = await stagehand.extract("get product prices", z.array(z.number()))
```

**When to use**: Natural language control, self-healing automation, unknown page structures.

See `tools/browser/stagehand.md` for full documentation.

### Crawl4AI - Web Scraping

**AI-powered web crawling and content extraction**

```bash
# Setup
bash ~/.aidevops/agents/scripts/crawl4ai-helper.sh setup

# Crawl and extract
crawl4ai https://example.com --extract "main content"
```

**When to use**: Web scraping, content extraction, bulk data collection.

See `tools/browser/crawl4ai.md` for full documentation.

## Debugging Checklist

When automation fails, check in this order:

1. **Screenshot**: `agent-browser screenshot /tmp/debug.png`
2. **Errors**: `agent-browser errors`
3. **Console**: `agent-browser console`
4. **URL**: `agent-browser get url` (redirected?)
5. **Snapshot**: `agent-browser snapshot -i` (elements changed?)
6. **Visibility**: `agent-browser is visible @eX`
7. **Headed mode**: `agent-browser open url --headed` (watch it happen)

**Only ask the user after exhausting these self-diagnosis steps.**

## Ethical Guidelines

- **Respect ToS**: Check site terms before automating
- **Rate limit**: 2-5 second delays between actions
- **No spam**: Don't automate mass messaging or fake engagement
- **Legitimate use**: Focus on genuine value, not manipulation
- **Privacy**: Don't scrape personal data without consent
