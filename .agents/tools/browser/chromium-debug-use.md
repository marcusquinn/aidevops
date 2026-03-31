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

- **Purpose**: Reuse an already-open Chrome/Chromium/Brave/Edge session instead of launching a fresh browser
- **Mechanism**: Start the browser with `--remote-debugging-port=9222`, then attach with Playwright CDP
- **Best for**: Logged-in/manual-auth flows, extension-heavy sessions, debugging real state, handoff between manual and scripted work
- **Not for**: Isolated parallel test runs, Firefox/WebKit, or hostile sites where exposed remote debugging is unsafe

**Core rule**: This pattern attaches to a live browser profile. Treat it as stateful and non-isolated. Prefer fresh Playwright contexts for reproducible tests.

<!-- AI-CONTEXT-END -->

## Start a Debuggable Browser

Use a dedicated profile when possible.

```bash
# Chrome
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile

# Chromium
chromium \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chromium-debug-use-profile
```

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
| Need repeatable tests | Stop using live-session attach; launch a fresh Playwright context instead |

## Related

- `tools/browser/browser-automation.md` - browser tool selection
- `tools/browser/playwright.md` - fresh browser automation and CDP usage
- `tools/browser/dev-browser.md` - managed persistent Chromium profile on port 9222
- `tools/browser/chrome-devtools.md` - inspection and performance tooling over the same debug port
