---
description: Attach Playwright to a live Chromium session via remote debugging
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
- **Mechanism**: Start the browser with `--remote-debugging-port=9222`, then attach with Playwright CDP
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

## Related

- `tools/browser/browser-automation.md` - browser tool selection
- `tools/browser/playwright.md` - fresh browser automation and CDP usage
- `tools/browser/dev-browser.md` - managed persistent Chromium profile on port 9222
- `tools/browser/chrome-devtools.md` - inspection and performance tooling over the same debug port
