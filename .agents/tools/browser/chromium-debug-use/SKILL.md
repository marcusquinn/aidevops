---
name: chromium-debug-use
description: Attach to a user's already-open Chromium-family browser for live inspection and light interaction after explicit local approval
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chromium Debug Use

Read `tools/browser/chromium-debug-use.md` first.

## Use This Skill When

- The user wants help with something already open in Chrome, Brave, Edge, Vivaldi, Chromium, or a compatible Chromium build.
- The goal is to inspect current browser state before choosing a heavier automation tool.
- Aidevops needs a local-only, low-dependency path without requiring Playwright, Puppeteer, or a browser extension.

## Workflow

1. Confirm this is an explicit, user-approved live-session investigation.
2. Have the user launch the browser with the debug flag from `tools/browser/chromium-debug-use.md` if the endpoint is not already available.
3. Use `.agents/scripts/chromium-debug-use-helper.sh version` and `list` to confirm access.
4. Prefer `snapshot`, `html`, and `eval` to understand the page before using `click`, `type`, `navigate`, or `screenshot`.
5. Once the flow is understood, hand off to the best-fit longer-term tool:
   - `tools/browser/playwright.md` for repeatable isolated automation
   - `tools/browser/dev-browser.md` for an aidevops-managed persistent profile
   - `tools/browser/playwriter.md` for per-tab extension consent in the user's normal browser
   - `tools/browser/chrome-devtools.md` for performance, network, and console inspection

## Safety Rules

- Treat this access as local-only and temporary.
- Do not assume ambient access; the user must have enabled the debug path for this investigation.
- Prefer loopback endpoints and temporary profiles.
- Do not use this path for unrelated tabs or long-lived background control.

## Helper Commands

```bash
.agents/scripts/chromium-debug-use-helper.sh version
.agents/scripts/chromium-debug-use-helper.sh list
.agents/scripts/chromium-debug-use-helper.sh snapshot <target>
.agents/scripts/chromium-debug-use-helper.sh html <target> [selector]
.agents/scripts/chromium-debug-use-helper.sh eval <target> "document.title"
.agents/scripts/chromium-debug-use-helper.sh click <target> "button.submit"
.agents/scripts/chromium-debug-use-helper.sh type <target> "hello world"
.agents/scripts/chromium-debug-use-helper.sh screenshot <target> /tmp/page.png
```

Use `--browser-url http://127.0.0.1:9222` when the session is not on the default endpoint.
