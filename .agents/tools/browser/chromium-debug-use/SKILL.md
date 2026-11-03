---
name: chromium-debug-use
description: Use a logged-in Chromium-family session (Brave preferred) over CDP via an aidevops dedicated profile, after explicit local approval
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chromium Debug Use

Read `tools/browser/chromium-debug-use.md` first.

## Use This Skill When

The user wants the agent to use their logged-in session, or to inspect or lightly interact with a real Chromium-family browser (Brave, Chrome, Edge, Vivaldi, Chromium), before committing to a heavier automation tool.

## Workflow

1. Confirm explicit, user-approved live-session work. State up front that the user's already-open everyday tab cannot be attached (default-profile remote debugging is blocked; the extension is not documented for Brave).
2. Run `.agents/scripts/chromium-debug-use-helper.sh --profile cdp launch <url>`; the user logs in once in that window (the profile persists).
3. Use `.agents/scripts/chromium-debug-use-helper.sh --profile cdp version` and `--profile cdp list` to confirm access.
4. Keep `--profile cdp` on every page command. Prefer `snapshot`, `html`, and `eval` to understand the page before using `click`, `type`, `navigate`, or `screenshot`.
5. Once the flow is understood, hand off to the best-fit longer-term tool:
   - `tools/browser/playwright.md` — repeatable isolated automation
   - `tools/browser/dev-browser.md` — aidevops-managed persistent profile
   - `tools/browser/playwright.md` — official extension mode for selected tabs in the user's normal browser
   - `tools/browser/chrome-devtools.md` — performance, network, and console inspection

## Safety

- Local-only and interactive; never for headless workers or CI.
- Loopback endpoints and dedicated profiles only.
- Do not use this path for unrelated tabs or long-lived background control; run `launch-stop` when finished.

## Commands

```bash
.agents/scripts/chromium-debug-use-helper.sh --profile cdp launch [url]
.agents/scripts/chromium-debug-use-helper.sh --profile cdp launch-status
.agents/scripts/chromium-debug-use-helper.sh --profile cdp launch-stop
.agents/scripts/chromium-debug-use-helper.sh --profile cdp version
.agents/scripts/chromium-debug-use-helper.sh --profile cdp list
.agents/scripts/chromium-debug-use-helper.sh --profile cdp snapshot <target>
.agents/scripts/chromium-debug-use-helper.sh --profile cdp html <target> [selector]
.agents/scripts/chromium-debug-use-helper.sh --profile cdp eval <target> "document.title"
.agents/scripts/chromium-debug-use-helper.sh --profile cdp click <target> "button.submit"
.agents/scripts/chromium-debug-use-helper.sh --profile cdp type <target> "hello world"
.agents/scripts/chromium-debug-use-helper.sh --profile cdp screenshot <target> /tmp/page.png
```

Without `--profile` or an explicit endpoint, commands try `http://127.0.0.1:9222` first (for example `dev-browser`), then the first live launched profile found; discovery order is not guaranteed. Explicit endpoints are tried before port 9222. After `launch`, pass `--profile NAME` (default `cdp`) or `--browser-url http://127.0.0.1:<port>` to every page command; replace `cdp` in the examples when using another profile name.
