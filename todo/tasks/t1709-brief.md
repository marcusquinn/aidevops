<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1709: Integrate chromium-debug-use into browser routing and automation planning workflow

## Origin

- **Created:** 2026-03-31
- **Session:** OpenCode:unknown-2026-03-31
- **Created by:** ai-interactive
- **Parent task:** t1706
- **Conversation context:** The user wants `chromium-debug-use` not only for direct debugging but also as a fast way to understand a user's live workflow before formalizing automation with more purpose-built browser tools.

## What

Deepen aidevops browser-routing guidance so the already-landed `chromium-debug-use` route becomes a complete “inspect first, then automate intentionally” workflow. The deliverable must make the handoff points explicit: when the user should stay in `chromium-debug-use`, and when the agent should escalate to Playwright, dev-browser, Stagehand, Playwriter, or DevTools MCP.

## Why

PR #14956 added the basic browser-routing entry and guide links, but it did not yet establish the fuller “inspect before automating” workflow the user asked for. Without that deeper handoff guidance, workers will still default to heavier tools too early.

## How (Approach)

- Build on the existing decision-tree row in `.agents/tools/browser/browser-automation.md:27` so the docs explain the next step after live-session inspection.
- Update the feature/comparison guidance in `.agents/tools/browser/browser-automation.md:70`, `.agents/tools/browser/chromium-debug-use.md:107`, and `.agents/tools/browser/dev-browser.md:161` to position `chromium-debug-use` relative to Playwriter, DevTools MCP, dev-browser, and Playwright.
- Add or update top-level discovery references where browser tool selection is surfaced, including `.agents/build-plus.md:126`, `.agents/reference/domain-index.md:14`, and `.agents/aidevops/mcp-integrations.md:258` if needed.
- Document the workflow boundary: use `chromium-debug-use` to inspect current state and gather facts, then formalize repeatable automation with the stronger-purpose tool once the flow is understood.

## Acceptance Criteria

- [ ] The existing browser decision-tree route for live-session investigation is extended into a clear “inspect before automating” workflow.
- [ ] The comparison guidance explains when `chromium-debug-use` should hand off to Playwright, Stagehand, dev-browser, Playwriter, or DevTools MCP.
- [ ] The docs explicitly mention using the live session to understand or design an automation request before formalizing it.
- [ ] Discovery/index references are updated so the new capability is findable from the main browser-routing entry points.
- [ ] Tests pass (project-specific validation for changed docs).
- [ ] Lint clean (`markdownlint-cli2`).

## Context & Decisions

- The new tool should be presented as a fast investigation aid, not as a universal browser automation default.
- Some routing foundation already shipped via PR #14956; this task is the deeper workflow pass, not a first introduction.
- Tool handoff clarity matters more than maximizing the new tool's scope.
- Existing browser docs already contain most of the neighboring capabilities; this task is about routing and decision quality.

## Relevant Files

- `.agents/tools/browser/chromium-debug-use.md:107` — current trade-off section to extend with workflow handoff language.
- `.agents/tools/browser/browser-automation.md:27` — decision tree entry already added on main.
- `.agents/tools/browser/browser-automation.md:70` — feature matrix/comparison area.
- `.agents/tools/browser/dev-browser.md:161` — existing comparison table.
- `.agents/build-plus.md:126` — top-level browser automation route.
- `.agents/aidevops/mcp-integrations.md:258` — new guide link already added via PR #14956.
- `.agents/reference/domain-index.md:14` — browser domain discovery entry.

## Dependencies

- **Blocked by:** t1707, t1708
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review routing entry points and comparison tables |
| Implementation | 1h | Update decision tree, comparisons, and discovery references |
| Testing | 15m | Markdown lint and routing sanity pass |
| **Total** | **1h30m** | |
