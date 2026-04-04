<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1706: Chromium Debug Use Live Chromium Session Skill

## Origin

- **Created:** 2026-03-31
- **Session:** OpenCode:unknown-2026-03-31
- **Created by:** ai-interactive
- **Parent task:** none
- **Conversation context:** The user asked for an aidevops-owned `chromium-debug-use` capability that can inspect what is already open in a Chromium browser, guide the user through enabling the required debugging path for the chosen browser, and act as a fast discovery step before deeper automation work.

## What

Deliver an aidevops-native live-session Chromium debugging/investigation capability named `chromium-debug-use`. The finished work must give the framework a clear, reusable path to attach to a user's already-open Chromium-family browser session, perform bounded inspection/interactions, explain how the user enables access for the requested browser, and hand off cleanly to the more purpose-built automation tools when the task becomes repeatable automation instead of one-off investigation.

## Why

The current browser stack covers isolated automation, extension-based attached automation, and DevTools inspection, but it does not have a clean aidevops-owned answer for “help me with what I already have open right now” that works across Chromium-family browsers without assuming a separate extension install. This gap slows down support/debugging tasks and makes early-stage automation design harder than it needs to be.

## How (Approach)

- Add a new primary browser doc at `.agents/tools/browser/chromium-debug-use.md` and companion skill entry point at `.agents/tools/browser/chromium-debug-use/SKILL.md`, following the concise structure used by `.agents/tools/browser/playwriter.md:17` and `.agents/tools/browser/chrome-devtools.md:15`.
- Add a lightweight local helper path under `.agents/scripts/` or the tool directory for listing tabs and performing bounded CDP operations, grounded in the existing browser-selection guidance at `.agents/tools/browser/browser-automation.md:17` and `.agents/tools/browser/browser-automation.md:69`.
- Update high-level routing and discovery references so the new tool sits correctly beside Playwriter, DevTools MCP, and dev-browser (`.agents/build-plus.md:124`, `.agents/tools/browser/dev-browser.md:21`, `.agents/tools/browser/chrome-devtools.md:21`).
- Keep the v1 scope explicit: Chromium-family browsers first, explicit user approval before attachment, Electron/macOS extension paths documented as follow-up scope rather than implied support.

## Acceptance Criteria

- [ ] A new aidevops-owned `chromium-debug-use` browser capability exists with a primary doc and skill entry point.
- [ ] The capability is documented as an explicit-consent live-session attach path for already-open Chromium-family browsers.
- [ ] The core documented operations cover tab discovery plus bounded inspect/interact actions suitable for live debugging and investigation.
- [ ] The routing docs explain when to use `chromium-debug-use` instead of Playwriter, DevTools MCP, dev-browser, or Playwright.
- [ ] The v1 scope and the future Electron/macOS extension boundaries are documented clearly enough that workers do not over-promise support.
- [ ] Tests pass (project-specific validation for changed docs/helpers).
- [ ] Lint clean (`markdownlint-cli2`, `shellcheck` where applicable).

## Context & Decisions

- Chosen name: `chromium-debug-use`.
- The tool is intentionally narrower than a generic “browser use” agent; it is optimized for current-session inspection and light interaction.
- Explicit user approval is mandatory before attaching to a live browser session.
- V1 targets Chromium-family browsers; Electron support is deferred to documented adapter research.
- macOS automation is useful as a focus/discovery/handoff layer, not as a replacement for DOM-level browser automation.

## Relevant Files

- `.agents/tools/browser/browser-automation.md:17` — current decision tree that needs a live-session investigation route.
- `.agents/tools/browser/browser-automation.md:69` — feature matrix where the new capability will need positioning.
- `.agents/tools/browser/playwriter.md:17` — existing-browser automation pattern and comparison point.
- `.agents/tools/browser/chrome-devtools.md:21` — inspection/debugging companion capabilities to position against.
- `.agents/tools/browser/dev-browser.md:21` — persistent managed-browser alternative to contrast with live-session attach.
- `.agents/build-plus.md:124` — top-level routing entry for browser automation references.

## Dependencies

- **Blocked by:** none
- **Blocks:** t1707, t1708, t1709, t1710
- **External:** User-enabled remote debugging in a supported Chromium-family browser; local Node.js 22+ runtime for the helper path

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h15m | Review existing browser docs, attach model, and boundaries |
| Implementation | 4h | New tool docs, helper path, routing updates |
| Testing | 45m | Lint plus documented smoke verification |
| **Total** | **6h** | |
