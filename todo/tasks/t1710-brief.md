<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1710: Define Electron and macOS extension path for chromium-debug-use

## Origin

- **Created:** 2026-03-31
- **Session:** OpenCode:unknown-2026-03-31
- **Created by:** ai-interactive
- **Parent task:** t1706
- **Conversation context:** The user wants the plan to preserve future upside for Electron-based apps and macOS local automation, but without pretending broad support exists before the constraints are understood.

## What

Document the future extension envelope for the merged `chromium-debug-use` guide: which classes of Electron apps may be able to expose a compatible debugging path, where macOS-level app/window automation could help aidevops discover or focus the right local app/browser context, and what remains explicitly out of scope for v1. The deliverable should ground future follow-up work in documented constraints instead of implied promises.

## Why

Electron and macOS automation are attractive extensions, but they are easy to overstate. A bounded research task now prevents accidental scope creep and gives future workers a concrete starting point if the v1 Chromium capability proves useful.

## How (Approach)

- Extend `.agents/tools/browser/chromium-debug-use.md:126` with a clearly labeled future-scope section after the v1 behavior is defined.
- Use the current live-session positioning in `.agents/tools/browser/browser-automation.md:17`, `.agents/tools/browser/playwriter.md:29`, and `.agents/tools/browser/chrome-devtools.md:21` to explain where Electron/macOS follow-ups would complement rather than replace existing tools.
- Distinguish between: (1) Electron apps that expose CDP or can be launched with a debugging port, (2) macOS automation for focusing apps/windows or gathering local context, and (3) unsupported cases where no safe attach contract exists.
- End with concrete follow-up recommendations only if the research yields a bounded, testable next step.

## Acceptance Criteria

- [ ] The `chromium-debug-use` docs include a clearly labeled future scope section for Electron and macOS extensions.
- [ ] The docs distinguish supported v1 Chromium-browser behavior from speculative or adapter-specific follow-up work.
- [ ] The research explains where macOS automation helps and where it does not replace browser/CDP automation.
- [ ] The research explains why Electron support must be app-specific unless a reliable debugging contract exists.
- [ ] Any recommended follow-up is phrased as a separate bounded task, not implied current support.
- [ ] Tests pass (project-specific validation for changed docs).
- [ ] Lint clean (`markdownlint-cli2`).

## Context & Decisions

- This is intentionally a scope-definition task, not a promise to implement Electron support in the same phase.
- macOS automation is interesting mainly as a local discovery/focus layer.
- The main success condition is clearer boundaries, not more code.

## Relevant Files

- `.agents/tools/browser/chromium-debug-use.md:126` — existing related/trade-off area where future-scope guidance can be anchored.
- `.agents/tools/browser/browser-automation.md:17` — existing routing language for browser tool choice.
- `.agents/tools/browser/playwriter.md:29` — current-browser framing to compare with.
- `.agents/tools/browser/chrome-devtools.md:21` — browser-agnostic debugging/inspection positioning.

## Dependencies

- **Blocked by:** t1707
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 25m | Review Electron/macOS extension envelope and current browser docs |
| Implementation | 25m | Write future-scope section and recommendations |
| Testing | 10m | Markdown lint and clarity pass |
| **Total** | **1h** | |
