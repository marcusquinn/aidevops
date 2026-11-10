<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t18956: show addressable session-ID token in session and terminal titles

Issue: GH#37630

## What

Show a short, addressable session token (`@` + the last 6 characters of the OpenCode session ID, lowercased, e.g. `· @nk5je5`) at the end of interactive root-session titles, so users can read the address for `aidevops_sessions` / `aidevops sessions send` from the OpenCode 1.x right-sidebar title and the Tabby tab title.

## Why

Session-to-session messaging is in daily use, but the address (session ID or handle) is only visible via `aidevops_sessions list`. Handles change once a session claims an issue (`aidevops-37605`), while the session-ID suffix is stable for the life of the session.

## How

- Shared helpers to append/strip the token idempotently, coexisting with the paused `· AIDevOps <version>` suffix:
  - `.agents/plugins/opencode-aidevops/session-title-suffix.mjs` (plugin, session.created/updated handler: root, interactive sessions only)
  - `.agents/plugins/opencode-aidevops/session-title-fallback.mjs` (fallback title path)
  - `.opencode/lib/session-title-suffix.ts`, `.opencode/lib/session-rename-guards.ts`, `.opencode/tool/session-rename.ts` (session-rename tool writes SQLite directly, so no plugin event fires)
  - `.agents/scripts/session-rename-helper.sh` (shell rename / sync-branch path)
- Resolver: `.agents/plugins/opencode-aidevops/session-bus-targets.mjs` accepts `@xxxxxx` (and bare 6+ char session-ID suffix) in `to` and `who`; ambiguity keeps the existing candidate error.
- Presence: `.agents/plugins/opencode-aidevops/session-bus-presence.mjs` stores titles without the token (list output already shows the full session ID).
- OpenCode 2 TUI: `.agents/plugins/opencode-aidevops/v2-plugin/tui.mjs` appends the token to the terminal title after truncation (V2 titles are tab labels, so not stored).

### Files Scope

- `.agents/plugins/opencode-aidevops/session-title-suffix.mjs`
- `.agents/plugins/opencode-aidevops/session-title-fallback.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-targets.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-presence.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/v2-plugin/tui.mjs`
- `.opencode/lib/session-title-suffix.ts`
- `.opencode/lib/session-rename-guards.ts`
- `.opencode/tool/session-rename.ts`
- `.agents/scripts/session-rename-helper.sh`

## Acceptance

- A live interactive OpenCode 1.x session shows `… · @xxxxxx` in the sidebar title and Tabby tab; `aidevops_sessions send to=@xxxxxx` resolves it.
- Renames via the `session-rename` tool keep the purpose-preserving behaviour and exactly one token.
- Subagent child sessions and headless workers are unchanged.

## Verification

- `node --test .agents/plugins/opencode-aidevops/tests/test-session-title-suffix.mjs .agents/plugins/opencode-aidevops/tests/test-session-bus.mjs .agents/plugins/opencode-aidevops/tests/test-session-bus-who.mjs .agents/plugins/opencode-aidevops/tests/test-opencode-v2-tui-title.mjs`
- `bun .agents/scripts/tests/bun/test-session-rename-ts.mjs`; `bash .agents/scripts/tests/test-session-rename-helper.sh`; `shellcheck .agents/scripts/session-rename-helper.sh`
- Deploy with `setup.sh --non-interactive` and check a live session title.
