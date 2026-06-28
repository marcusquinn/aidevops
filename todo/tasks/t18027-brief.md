<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18027: Polish GUI app interactions and contrast controls

## Pre-flight

- [x] Memory recall: `aidevops GUI PR release issue full-loop workflow branch worktree` and `aidevops release setup symlink version manager canonical repo` → 0 hits in current memory tool — prior session checkpoint carried release/setup caution context.
- [x] Discovery pass: duplicate search found no open issue or PR for `GUI app tooltip external browser contrast` in `marcusquinn/aidevops`.
- [x] File refs verified: target paths exist in the current worktree and are covered by the implementation diff.
- [x] Tier: `tier:standard` — cross-package GUI web + desktop shell changes with fallback behavior and accessibility/UI interactions.
- [x] Seeded draft PR decision recorded: skipped — implementation is already staged in the current interactive branch for a normal PR.

## Origin

- **Created:** 2026-06-28
- **Session:** OpenCode interactive session
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** Follow-up GUI polish requested after the Apps surface split and previous Apps tooltip/version fixes.

## What

Polish the GUI Apps and Appearance interactions so custom tooltips, external links, header popovers, recommended app tiles, dashboard navigation, and contrast settings behave consistently in the web UI and macOS desktop shell.

## Why

The GUI needs to avoid duplicate native browser tooltips, align custom tooltips with their real targets, open external URLs in the host default browser from the desktop shell, dismiss header menus predictably, improve recommended app tile affordances, and expose explicit low/medium/high contrast choices.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The work spans multiple GUI web components plus the macOS desktop shell installer script, includes fallback external-link behavior, and updates tests and CSS theme variants.

## PR Conventions

Leaf task: PR body should use `Resolves #25822`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Implementation already exists in `fix-gui-followups-contrast-links`; a regular PR is the appropriate review artifact.
- **Status:** `not-created`
- **Freshness evidence:** branch rebased onto `origin/main` before verification.
- **Verification run:** see Verification section.
- **Stale-assumption warning:** rerun focused GUI checks if upstream changes touch the Apps surface, desktop shell installer, or Appearance controls before merge.

## How (Approach)

### Reference pattern

Model on the existing Apps surface custom-tooltip approach in `packages/gui-web/src/InventorySurfaces.tsx`, the existing app-origin link affordances in `packages/gui-web/src/ManagedAppPanel.tsx` and `packages/gui-web/src/RecommendedAppsSurface.tsx`, and the existing WebKit bridge pattern for accent hue messages in `packages/gui-desktop/scripts/install-macos-app.sh`.

### Files to Modify

- `packages/gui-web/src/external-links.ts` — shared external-link opener and WebKit message bridge.
- `packages/gui-desktop/scripts/install-macos-app.sh` — generated Swift WebKit wrapper handling `externalLink` messages and HTTP(S) URL opening via `NSWorkspace`.
- `packages/gui-web/src/ManagedAppPanel.tsx` — managed app links, summary chips, and locked policy toggle tooltips.
- `packages/gui-web/src/RecommendedAppsSurface.tsx` — recommended app title links, URL tooltips, filter icon buttons, and shared link helper.
- `packages/gui-web/src/InventorySurfaces.tsx` — global tooltip alignment state and viewport-edge placement.
- `packages/gui-web/src/AppWorkspace.tsx` — header popover mutual exclusion, click-away/Escape close, and delayed hover-away close.
- `packages/gui-web/src/AppNavigation.tsx` — logo dashboard navigation and Appearance contrast controls.
- `packages/gui-web/src/AppearanceControls.tsx` — extracted Appearance footer controls and hue parsing helper.
- `packages/gui-web/src/workspace-header-state.ts` — extracted header menu state and command palette selection helpers.
- `packages/gui-web/src/App.tsx` — contrast persistence and document dataset wiring.
- `packages/gui-web/src/app-model.ts` — contrast preference type, options, default, validator, and label copy.
- `packages/gui-web/src/styles.css` — tooltip placement, app icon hit-area alignment, recommended tile hover/focus states, and contrast CSS variables.
- `packages/gui-web/src/dashboard.ts` — static dashboard copy for Appearance controls.
- `packages/gui-web/tests/component.test.ts` — regression coverage for custom tooltip/link source and contrast preferences.
- `packages/gui-api/tests/security.test.ts` — targeted timeout stabilization for the full local status redaction route test.

### Implementation Steps

1. Add a shared external-link helper that preserves modifier-click browser behavior and uses the macOS WebKit `externalLink` message handler when available.
2. Add the native `externalLink` handler in the desktop shell and route HTTP(S) URLs through `NSWorkspace.shared.open`.
3. Remove native `title` attributes where custom `data-tooltip` tooltips already exist.
4. Make recommended app names clickable website links with URL tooltips and add rollover styling for recommendation tiles.
5. Make global Apps tooltips edge-aware so they appear above the actual hovered link or badge.
6. Ensure header menus close each other, close on click-away/Escape, and close after hover-away delay.
7. Make the logo return to Dashboard and restore the devices rail mode.
8. Add persisted low/medium/high Appearance contrast preferences with CSS theme variants.
9. Allow the full local `/api/status` redaction test up to 10 seconds because it exercises local status probes and can exceed Bun's 5-second default on loaded developer machines.
10. Extract Appearance controls and header menu state into smaller modules to keep the Qlty smell threshold/regression gates clean.

### Verification

- `bun test packages/gui-web/tests`
- `bun test packages/gui-api/tests`
- `bun run typecheck`
- `bash -n packages/gui-desktop/scripts/install-macos-app.sh`
- `shellcheck packages/gui-desktop/scripts/install-macos-app.sh`
- `bun run gui:desktop:check`
- `git diff --check`
- `qlty smells --all --sarif --no-snippets --quiet` / `.agents/scripts/qlty-regression-helper.sh --base origin/main --head HEAD`

## Acceptance

- Custom tooltip targets no longer show duplicate native browser title tooltips.
- Apps and recommended-app links open in the host OS default browser from the macOS desktop shell.
- Header notification, AI, and profile controls hide each other and dismiss on outside click, Escape, or delayed hover-away.
- Recommended app tiles visibly react on hover/focus, and app names link to their websites with URL tooltips.
- Dashboard logo click returns to the Dashboard surface and device mode.
- Appearance exposes Contrast low, medium, and high, persists the choice, and applies corresponding CSS variables.
- Focused GUI tests, typecheck, desktop-shell checks, shell syntax/lint, and diff whitespace checks pass.

## Context

- Implementation commit after rebase: `d782d0535 fix: polish GUI app interactions`.
- Initial parallel `bun test packages/gui-api/tests` had one 5s timeout under load; the same suite passed when rerun serially.
