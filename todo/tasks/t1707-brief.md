<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1707: Create chromium-debug-use skill doc and local CDP helper wrapper

## Origin

- **Created:** 2026-03-31
- **Session:** OpenCode:unknown-2026-03-31
- **Created by:** ai-interactive
- **Parent task:** t1706
- **Conversation context:** The user wants the new `chromium-debug-use` capability to be aidevops-owned, low-dependency, and focused on investigating the live browser state the user already has open.

## What

Build on the merged `chromium-debug-use` browser guide by adding the missing loadable skill entry point and a lightweight helper wrapper that can attach to a supported Chromium-family browser session and expose the minimum inspect/interact operations needed for live debugging. The deliverable must let future sessions load and use the capability directly, rather than treating the guide as static reference-only documentation.

## Why

PR #14956 established the guide and basic routing, but it did not add a loadable skill entry point or an aidevops-owned helper surface for repeated use. Without those pieces, the concept remains partly documentary rather than a routable framework capability.

## How (Approach)

- Preserve `.agents/tools/browser/chromium-debug-use.md:13` as the primary human-facing guide and add `.agents/tools/browser/chromium-debug-use/SKILL.md` as the loadable skill entry.
- Add a lightweight local helper wrapper under `.agents/scripts/` (or a colocated script path referenced by the doc) that covers list/snapshot/html/eval/screenshot/click/type style operations for live tabs.
- Follow the positioning and comparison language already used in `.agents/tools/browser/browser-automation.md:17` and `.agents/tools/browser/chromium-debug-use.md:19` so the helper is framed as a fast attach path rather than a broad automation framework.
- Keep the helper local-only and minimal-dependency; prefer a Node 22+ / direct-CDP path over introducing Playwright as a required dependency for v1.

## Acceptance Criteria

- [ ] `.agents/tools/browser/chromium-debug-use.md` remains the primary guide and is extended only as needed for the helper path.
- [ ] `.agents/tools/browser/chromium-debug-use/SKILL.md` exists and gives the runtime a loadable entry point for the capability.
- [ ] A helper wrapper exists and documents or implements tab listing plus bounded inspect/interact operations for supported Chromium-family browsers.
- [ ] The helper path is explicitly documented as local-only and based on user-enabled browser debugging access.
- [ ] The capability does not require Playwright, Stagehand, or a browser extension as a mandatory v1 dependency.
- [ ] Tests pass (project-specific validation for docs/helper additions).
- [ ] Lint clean (`markdownlint-cli2`, `shellcheck` where applicable).

## Context & Decisions

- The goal is an aidevops-owned implementation surface, not a thin pointer to the upstream repo.
- The guide itself already exists on `main`; this task should extend it rather than recreate it.
- v1 should be useful with low setup friction and a narrow command surface.
- The capability should remain clearly narrower than Playwriter and Playwright.
- If a shell wrapper is added, it must remain Bash 3.2 compatible and ShellCheck clean.

## Relevant Files

- `.agents/tools/browser/chromium-debug-use.md:13` — existing guide to preserve and extend.
- `.agents/tools/browser/playwriter.md:23` — current attached-browser comparison point.
- `.agents/tools/browser/chrome-devtools.md:21` — existing inspection/debugging positioning.
- `.agents/tools/browser/browser-automation.md:17` — current decision-tree placement already added in foundation work.
- `.agents/tools/browser/browser-automation.md:70` — feature matrix area for future positioning updates if needed.

## Dependencies

- **Blocked by:** none
- **Blocks:** t1709, t1710
- **External:** Local Node.js 22+ and a supported Chromium-family browser with debugging enabled by the user

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review doc structure and helper conventions |
| Implementation | 1h30m | Create doc, skill entry point, helper wrapper |
| Testing | 15m | Lint and smoke-path validation notes |
| **Total** | **2h** | |
