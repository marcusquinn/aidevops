---
description: Attach to a live Chromium session via local CDP helper or Playwright
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
  task: true
---

# Chromium Debug Use

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Reuse an already-open Chrome/Chromium/Brave/Edge/Vivaldi session instead of launching a fresh browser
- **Mechanism**: Start the browser with `--remote-debugging-port=9222`, then attach with the local CDP helper or Playwright CDP
- **Helper**: `.agents/scripts/chromium-debug-use-helper.sh` (Node 22+, raw CDP, no Playwright dependency)
- **Skill entry**: `tools/browser/chromium-debug-use/SKILL.md`
- **Best for**: Logged-in/manual-auth flows, extension-heavy sessions, debugging real state, handoff between manual and scripted work
- **Not for**: Isolated parallel test runs, Firefox/WebKit, or hostile sites where exposed remote debugging is unsafe

**Core rule**: This pattern attaches to a live browser profile. Treat it as stateful and non-isolated. Prefer fresh Playwright contexts for reproducible tests.

<!-- AI-CONTEXT-END -->

## Enable Only for This Investigation

Use this path only when aidevops explicitly needs to inspect or automate your live Chromium-family browser. Do not leave remote debugging enabled as a standing default.

Launching with `--remote-debugging-port=9222` grants local processes profile-level access (cookies, local storage, logged-in tabs) until you close that browser or restart it without the flag.

Security boundaries:

- Bind to loopback only: `http://127.0.0.1:9222`, not a LAN IP.
- Prefer a temporary `--user-data-dir` so investigation state is isolated and easy to discard.
- For per-tab consent instead of profile-level, use `tools/browser/playwriter.md`.

## Start a Debuggable Browser

Use a dedicated profile when possible. All Chromium-family browsers accept the same flags:

```bash
--remote-debugging-port=9222 --user-data-dir=/tmp/chromium-debug-use-profile
```

| Browser | macOS executable path |
|---------|----------------------|
| Chrome | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` |
| Brave | `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser` |
| Edge | `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` |
| Vivaldi | `/Applications/Vivaldi.app/Contents/MacOS/Vivaldi` |
| Chromium | `chromium` (or `/Applications/Chromium.app/Contents/MacOS/Chromium`) |
| Ungoogled Chromium | `/Applications/Ungoogled Chromium.app/Contents/MacOS/Ungoogled Chromium` |

On Linux: `which google-chrome`, `which chromium`, or `/opt/...`. On Windows: `where chrome.exe`.

**Ungoogled Chromium caveat**: Support is build-dependent. If `/json/version` is not exposed, treat that build as unsupported and fall back to Chrome/Brave/Edge/Vivaldi/Chromium or `tools/browser/playwriter.md`.

Verify the endpoint after launch:

```bash
curl http://127.0.0.1:9222/json/version
```

Use loopback only. Never expose the debug port to untrusted networks.

## Use the Local Helper

The helper provides a direct CDP command surface without requiring Playwright or Puppeteer.

```bash
# browser version / endpoint sanity check
.agents/scripts/chromium-debug-use-helper.sh version

# list open tabs and target prefixes
.agents/scripts/chromium-debug-use-helper.sh list

# inspect one page
.agents/scripts/chromium-debug-use-helper.sh snapshot <target>
.agents/scripts/chromium-debug-use-helper.sh html <target> main
.agents/scripts/chromium-debug-use-helper.sh eval <target> "document.title"

# interact lightly in the live session
.agents/scripts/chromium-debug-use-helper.sh click <target> "button[type='submit']"
.agents/scripts/chromium-debug-use-helper.sh type <target> "hello world"
.agents/scripts/chromium-debug-use-helper.sh screenshot <target> /tmp/chromium-debug-use.png
```

Notes:

- Commands default to `http://127.0.0.1:9222`, then fall back to browser `DevToolsActivePort` discovery.
- Override with `--browser-url http://127.0.0.1:9333` or `CHROMIUM_DEBUG_USE_BROWSER_URL=...`.
- The helper uses raw CDP over WebSocket with a per-tab daemon — repeated commands do not reconnect.
- Run `list` first, then use the displayed target prefix for page-specific commands.

## Attach with Playwright

```javascript
import { chromium } from 'playwright';

const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
const context = browser.contexts()[0];
const page = context.pages()[0] ?? await context.newPage();

await page.goto('https://example.com');
console.log({ title: await page.title(), url: page.url() });

await browser.close(); // disconnects; does not close the live browser
```

If the HTTP endpoint is unavailable, read `webSocketDebuggerUrl` from `/json/version` and attach directly:

```javascript
const browser = await chromium.connectOverCDP(
  'ws://127.0.0.1:9222/devtools/browser/<id>'
);
```

## Common Patterns

### Reuse manual login

1. Start Chromium with remote debugging.
2. Complete login or CAPTCHA manually.
3. Attach with Playwright CDP.
4. Continue scripted actions in the same session.

### Inspect existing tabs

```javascript
const pages = browser.contexts().flatMap(ctx => ctx.pages());
for (const page of pages) {
  console.log(page.url());
}
```

### Pair with Chrome DevTools MCP

```bash
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
```

Use CDP attachment for automation and DevTools MCP for performance, network, and console inspection against the same live browser.

## Browser and Tool Selection

Choose the consent model and tool that matches the task:

| Need | Prefer |
|------|--------|
| Reuse a whole live Chromium profile | Chromium Debug Use (this doc) |
| Approve only selected tabs in your everyday browser | `tools/browser/playwriter.md` |
| Persistent local profile managed by aidevops | `tools/browser/dev-browser.md` |
| Fast isolated automation or CI | `tools/browser/playwright.md` |
| Inspection/perf analysis without reusing your active session | `tools/browser/chrome-devtools.md` |

For Chrome, Brave, Edge, and Vivaldi, enablement requires relaunching with the debug flag. For Playwriter, enablement requires clicking the extension per tab. In both cases, treat the session as local-only and user-approved — not ambient or permanent.

## Workflow Boundary

Inspect and gather facts with `chromium-debug-use`, then hand off to the stronger-purpose tool:

| After inspection, if you need... | Hand off to... | Why |
|----------------------------------|----------------|-----|
| Repeatable scripts, clean state, parallel runs, or CI | `tools/browser/playwright.md` | Fresh contexts are more reliable than a live user session |
| A managed persistent profile that aidevops can keep reusing | `tools/browser/dev-browser.md` | Better for ongoing stateful automation owned by aidevops |
| Everyday-browser, tab-by-tab consent | `tools/browser/playwriter.md` | Narrower consent boundary than profile-level remote debugging |
| Deeper console, network, or performance debugging on the same session | `tools/browser/chrome-devtools.md` | Better inspection surface once you know the target tab |
| Natural-language experimentation before you lock in selectors or code | `tools/browser/stagehand.md` | Better when the next step is exploratory automation design |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ECONNREFUSED` on `9222` | Browser was not started with `--remote-debugging-port=9222` |
| No pages found | Open a tab manually or create one with `context.newPage()` |
| Attach works but state is wrong | You launched a different profile than expected; verify `--user-data-dir` |
| Browser closes unexpectedly | Another tool owns the session or the profile lock; use a dedicated debug profile |
| Browser policy or packaging blocks remote debugging | Use `tools/browser/playwriter.md` for tab-level consent or `tools/browser/chrome-devtools.md --headless` for isolated inspection |
| You do not want to relaunch your browser | Use `tools/browser/playwriter.md` instead of profile-level CDP attach |
| Ungoogled Chromium never exposes `/json/version` | Treat that build as unsupported; switch to Chrome/Brave/Edge/Vivaldi/Chromium |
| Need repeatable tests | Stop using live-session attach; launch a fresh Playwright context instead |

## Future Scope: Electron and macOS Extension Path

> **v1 scope boundary**: Everything above describes supported v1 behavior — attaching to Chromium-family browsers launched with `--remote-debugging-port`. The section below documents the extension envelope for future work. None of it implies current support.

### Electron Apps

Electron embeds Chromium and can expose a CDP endpoint, but there is no universal contract.

CDP attachment may work when: the app is launched with `--remote-debugging-port=N`; the app does not call `app.commandLine.removeSwitch('remote-debugging-port')`; and the app does not use `BrowserWindow.webContents.debugger` in a conflicting way.

Electron support must be app-specific because: each app controls whether the debug port is exposed; apps with auto-update or code signing may reject modified launch arguments; the CDP surface reflects `BrowserWindow` contents, not a general tab list; and some apps (VS Code, Figma desktop, Slack) accept the flag in dev builds but block it in production packaging.

**Decision rule**: Before implementing, verify the target app exposes a working `/json/version` endpoint when launched with the debug flag. If it does not, this workflow does not apply.

### macOS App and Window Automation

macOS provides two OS-level automation layers that complement (but do not replace) CDP:

| Layer | What it can do | What it cannot do |
|-------|---------------|-------------------|
| AppleScript / `osascript` | Activate apps, bring windows to front, send menu commands, switch tabs in Safari/Chrome | Read DOM state, execute JS, intercept network requests |
| Accessibility API (`AXUIElement`) | Enumerate windows and UI elements for apps that expose the accessibility tree | Access web content inside a `WKWebView` or Electron `BrowserWindow` |

Use macOS automation only as a discovery or focus layer — to get the right app/window into position before handing off to CDP or Playwright. AppleScript cannot reach inside a web page; CDP `Runtime.evaluate` is required for JS execution; CDP `Network` domain or a proxy is required for network interception.

### Explicit Out-of-Scope for v1

- Attaching to Safari via CDP (Safari uses WebKit Inspector Protocol, not CDP)
- Attaching to Firefox (uses its own remote debugging protocol, not CDP)
- Attaching to Electron apps without a confirmed working debug port
- Using macOS Accessibility API to read web page content
- Automating iOS simulators or real devices via this workflow (use Maestro or `tools/mobile/`)

## Related

- `tools/browser/browser-automation.md` - browser tool selection
- `tools/browser/playwright.md` - fresh browser automation and CDP usage
- `tools/browser/dev-browser.md` - managed persistent Chromium profile on port 9222
- `tools/browser/chrome-devtools.md` - inspection and performance tooling over the same debug port
