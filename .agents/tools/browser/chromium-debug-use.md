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

What you are approving when you launch with `--remote-debugging-port=9222`:

- Local processes on your machine can inspect and automate tabs in that browser profile.
- Session state in that profile (cookies, local storage, logged-in tabs) becomes available to the attached tool.
- The approval lasts until you close that debug-enabled browser or restart it without the flag.

Security boundaries:

- Bind to loopback only: `http://127.0.0.1:9222`, not a LAN IP.
- Prefer a temporary `--user-data-dir` so investigation state is isolated and easy to discard.
- If you want per-tab, click-to-connect consent instead of profile-level consent, use `tools/browser/playwriter.md`.

## Start a Debuggable Browser

Use a dedicated profile when possible.

### Chrome

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile
```

Adjust the executable path for your platform. On Linux, check `which google-chrome`, `which chromium`, or `/opt/...`; on Windows, use `where chrome.exe` or the installed path under `C:\Program Files\...`.

Approval model: by launching Chrome with the debug port, you are granting local tooling profile-level access for this temporary investigation window.

### Brave

```bash
"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile
```

Use Brave when the issue depends on your normal extension stack or privacy defaults, but still prefer a temporary profile unless the investigation requires your existing state.

### Edge

```bash
"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile
```

Use Edge when the behavior is browser-specific or policy-specific. The consent scope is the same: local profile-level control while that flagged browser stays open.

### Vivaldi

```bash
"/Applications/Vivaldi.app/Contents/MacOS/Vivaldi" \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile
```

Vivaldi usually behaves like other Chromium browsers for CDP attachment, but custom UI features do not change the underlying consent model: attach is still local and profile-scoped.

### Chromium

```bash
chromium \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile
```

This is the cleanest baseline when you want Chromium behavior without vendor-specific browser features.

### Ungoogled Chromium

```bash
"/Applications/Ungoogled Chromium.app/Contents/MacOS/Ungoogled Chromium" \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile
```

Support is build-dependent. If your Ungoogled Chromium package does not expose a working DevTools endpoint at `127.0.0.1:9222`, treat this path as unsupported for that build and fall back to a supported Chromium browser, `tools/browser/playwriter.md`, or `tools/browser/chrome-devtools.md` in headless mode.

Check the endpoint:

```bash
curl http://127.0.0.1:9222/json/version
```

Use loopback only. Never expose the debug port to untrusted networks.

## Use the Local Helper

The helper gives aidevops a small, direct CDP command surface without requiring Playwright or Puppeteer.

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
- Override the endpoint with `--browser-url http://127.0.0.1:9333` or `CHROMIUM_DEBUG_USE_BROWSER_URL=...`.
- The helper uses raw CDP over WebSocket and keeps a per-tab daemon so repeated commands do not require reconnecting every time.
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

## Attach by WebSocket Endpoint

If an HTTP endpoint is unavailable, read `webSocketDebuggerUrl` from `/json/version` and attach directly.

```bash
curl http://127.0.0.1:9222/json/version
```

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

## Consent and Browser Choice

Choose the consent model that matches the task:

| Need | Consent model | Prefer |
|------|---------------|--------|
| Reuse a whole live Chromium profile | Start browser with debug flag | Chromium Debug Use |
| Approve only selected tabs in your everyday browser | Click extension per tab | `tools/browser/playwriter.md` |
| Inspection/perf analysis without reusing your active session | Launch or connect DevTools MCP | `tools/browser/chrome-devtools.md` |

For Chrome, Brave, Edge, and Vivaldi, the enablement step is explicit because you must relaunch the browser with the debug flag. For Playwriter, the enablement step is explicit because you must click the extension on the tab you want to share. In both cases, aidevops should treat the session as local-only and user-approved, not ambient or permanent access.

## Trade-offs

| Need | Prefer |
|------|--------|
| Existing logged-in Chromium session | Chromium Debug Use |
| Persistent local profile managed by aidevops | `tools/browser/dev-browser.md` |
| Your everyday browser with extension click-to-connect | `tools/browser/playwriter.md` |
| Fast isolated automation | `tools/browser/playwright.md` |

## Workflow Boundary

Use this tool to understand what is already happening in a live Chromium session. Once the flow is understood, move to the tool that matches the long-term job instead of keeping every task attached to the live browser.

| After inspection, if you need... | Hand off to... | Why |
|----------------------------------|----------------|-----|
| Repeatable scripts, clean state, parallel runs, or CI | `tools/browser/playwright.md` | Fresh contexts are more reliable than a live user session |
| A managed persistent profile that aidevops can keep reusing | `tools/browser/dev-browser.md` | Better for ongoing stateful automation owned by aidevops |
| Everyday-browser, tab-by-tab consent | `tools/browser/playwriter.md` | Narrower consent boundary than profile-level remote debugging |
| Deeper console, network, or performance debugging on the same session | `tools/browser/chrome-devtools.md` | Better inspection surface once you know the target tab |
| Natural-language experimentation before you lock in selectors or code | `tools/browser/stagehand.md` | Better when the next step is exploratory automation design |

Rule of thumb: inspect and gather facts with `chromium-debug-use`, then formalize the durable workflow with the stronger-purpose browser tool.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ECONNREFUSED` on `9222` | Browser was not started with `--remote-debugging-port=9222` |
| No pages found | Open a tab manually or create one with `context.newPage()` |
| Attach works but state is wrong | You launched a different profile than expected; verify `--user-data-dir` |
| Browser closes unexpectedly | Another tool owns the session or the profile lock; use a dedicated debug profile |
| Browser policy or packaging blocks remote debugging | Use `tools/browser/playwriter.md` for tab-level consent or `tools/browser/chrome-devtools.md --headless` for isolated inspection |
| You do not want to relaunch your browser | Use `tools/browser/playwriter.md` instead of profile-level CDP attach |
| Ungoogled Chromium never exposes `/json/version` | Treat that build as unsupported for this workflow and switch to Chrome/Brave/Edge/Vivaldi/Chromium |
| Need repeatable tests | Stop using live-session attach; launch a fresh Playwright context instead |

## Future Scope: Electron and macOS Extension Path

> **v1 scope boundary**: Everything above this section describes supported v1 behavior — attaching to Chromium-family browsers launched with `--remote-debugging-port`. The section below documents the extension envelope for future work. None of it implies current support.

### Electron Apps

Electron embeds Chromium and can expose a CDP endpoint, but there is no universal contract.

**When Electron CDP attachment may work:**

- The app is launched with `--remote-debugging-port=N` (either by the user or via a launch script).
- The app does not call `app.commandLine.removeSwitch('remote-debugging-port')` or equivalent to block the flag.
- The app does not use `BrowserWindow.webContents.debugger` in a way that conflicts with external CDP attachment.

**Why Electron support must be app-specific:**

- Each Electron app controls whether the debug port is exposed. There is no OS-level mechanism to force it open.
- Apps that ship with auto-update or code signing may reject modified launch arguments.
- The CDP surface inside an Electron app reflects the app's `BrowserWindow` contents, not a general browser tab list. Navigation, extension, and cookie APIs behave differently than in a standalone browser.
- Some apps (VS Code, Figma desktop, Slack) have been tested to accept `--remote-debugging-port` in development builds but block it in production packaging.

**Decision rule for a future Electron task:** Before implementing, verify that the target app exposes a working `/json/version` endpoint when launched with the debug flag. If it does not, this workflow does not apply and there is no safe attach contract.

**Potential follow-up task (if v1 CDP proves useful):** Define a per-app Electron launch wrapper that sets `--remote-debugging-port` and verifies the endpoint before handing off to the helper. Scope to one specific app with a confirmed working debug path.

### macOS App and Window Automation

macOS provides two OS-level automation layers that complement (but do not replace) CDP:

| Layer | What it can do | What it cannot do |
|-------|---------------|-------------------|
| AppleScript / `osascript` | Activate apps, bring windows to front, send menu commands, switch tabs in Safari/Chrome | Read DOM state, execute JS, intercept network requests |
| Accessibility API (`AXUIElement`) | Enumerate windows and UI elements for apps that expose the accessibility tree | Access web content inside a `WKWebView` or Electron `BrowserWindow` |

**Where macOS automation helps aidevops:**

- Focusing the correct app or window before a CDP attach, so the right browser is in the foreground.
- Discovering which browser is frontmost when the user has not specified one.
- Switching tabs in browsers that do not expose CDP (e.g., Safari without the Web Inspector flag).
- Triggering app-level actions (open URL, new tab) via AppleScript when a debug port is not available.

**Where macOS automation does not replace CDP:**

- Reading or modifying DOM state requires CDP or a browser extension. AppleScript cannot reach inside a web page.
- Executing JavaScript in a page requires CDP `Runtime.evaluate`. There is no AppleScript equivalent.
- Network interception requires CDP `Network` domain or a proxy. macOS automation has no network layer.

**Decision rule for a future macOS task:** Use macOS automation only as a discovery or focus layer — to get the right app/window into position before handing off to CDP or Playwright. Do not attempt to replace CDP with AppleScript for any task that requires DOM or JS access.

### Explicit Out-of-Scope for v1

The following are not supported in v1 and should not be implied by any routing decision:

- Attaching to Safari via CDP (Safari uses WebKit Inspector Protocol, not CDP).
- Attaching to Firefox (uses its own remote debugging protocol, not CDP).
- Attaching to Electron apps without a confirmed working debug port.
- Using macOS Accessibility API to read web page content.
- Automating iOS simulators or real devices via this workflow (use Maestro or `tools/mobile/`).

## Related

- `tools/browser/browser-automation.md` - browser tool selection
- `tools/browser/playwright.md` - fresh browser automation and CDP usage
- `tools/browser/dev-browser.md` - managed persistent Chromium profile on port 9222
- `tools/browser/chrome-devtools.md` - inspection and performance tooling over the same debug port
