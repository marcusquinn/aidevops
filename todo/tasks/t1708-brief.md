<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1708: Add browser-specific enablement and consent guidance for Chromium browsers

## Origin

- **Created:** 2026-03-31
- **Session:** OpenCode:unknown-2026-03-31
- **Created by:** ai-interactive
- **Parent task:** t1706
- **Conversation context:** The user specifically wants `chromium-debug-use` to teach users what they need to do in the chosen browser before aidevops can inspect a live browser window or webapp.

## What

Extend the merged `chromium-debug-use` guide with clear, browser-specific setup and consent guidance, covering the Chromium-family browsers aidevops intends to support in v1. The final docs must tell the user how to enable the required debugging path for the mentioned browser, what approval they are giving when they do so, and what fallback to use when that path is unavailable or undesirable.

## Why

The attach model is only useful if users can confidently and safely enable it for the browser they actually use. Without explicit enablement and consent guidance, the tool will feel risky, incomplete, or brittle even if the low-level attach path works.

## How (Approach)

- Extend `.agents/tools/browser/chromium-debug-use.md:28` with browser-specific enablement sections for Chrome, Brave, Edge, Vivaldi, and Ungoogled Chromium, grounded in the multi-browser assumptions already present in `.agents/tools/browser/browser-automation.md:100`.
- Explain the explicit-consent model and position it relative to existing attached-browser tooling in `.agents/tools/browser/playwriter.md:136`.
- Add local-only security boundaries and troubleshooting/fallback guidance that points to `.agents/tools/browser/chrome-devtools.md:27` and `.agents/tools/browser/playwriter.md:41` when the live-session attach path is not the best fit.
- Ensure the guidance is phrased as “enable only when asked for this investigation” rather than a standing permanent recommendation.

## Acceptance Criteria

- [ ] The docs include browser-specific guidance for Chrome, Brave, Edge, Vivaldi, and Ungoogled Chromium.
- [ ] The docs explain what explicit approval the user is giving before aidevops attaches to the browser session.
- [ ] The docs describe the local-only scope and the security implications of enabling the debugging path.
- [ ] The docs include fallback guidance to Playwriter, DevTools MCP, or other browser tools when the attach path is unavailable or inappropriate.
- [ ] The wording makes it clear that this is an on-demand troubleshooting/investigation path, not something users must leave enabled indefinitely.
- [ ] Tests pass (project-specific validation for changed docs).
- [ ] Lint clean (`markdownlint-cli2`).

## Context & Decisions

- Browser-specific instructions are a first-class part of the deliverable, not an optional appendix.
- User approval must be explicit each time this path is used for live-session work.
- Guidance should optimize for confidence and reversibility.
- Unsupported or ambiguous browsers should be called out plainly instead of implied.

## Relevant Files

- `.agents/tools/browser/chromium-debug-use.md:28` — existing browser start/attach guidance to expand.
- `.agents/tools/browser/browser-automation.md:101` — existing multi-browser notes for other tools.
- `.agents/tools/browser/playwriter.md:136` — local safety/consent framing for attached-browser control.
- `.agents/tools/browser/chrome-devtools.md:27` — browser connection methods and troubleshooting patterns.

## Dependencies

- **Blocked by:** none
- **Blocks:** t1709
- **External:** Access to reliable browser enablement instructions for the supported Chromium-family browsers

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Confirm browser-specific wording and fallback paths |
| Implementation | 35m | Write enablement, consent, and troubleshooting sections |
| Testing | 10m | Markdown lint and clarity pass |
| **Total** | **1h** | |
