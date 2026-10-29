## What

Fix two defects in the OpenCode sidebar "Prompts" section added by the aidevops TUI plugin.

1. Rows for slash-command turns show the expanded command template (for example `<!-- SPDX-License-Identifier: MIT…` from `/full-loop`) instead of what the user typed.
2. Clicking a row briefly shows the native Timeline dialog, which closes immediately.

## Why (root causes, verified)

1. OpenCode `SessionPrompt.command()` (v1.19.5 `packages/opencode/src/session/prompt.ts`) stores the expanded template as an ordinary non-synthetic user text part, and no durable message field records the command name or arguments. `extractPromptRows()` in `.agents/plugins/opencode-aidevops/tui-prompts.mjs` therefore treats the 45 KB template (beginning with the command file's SPDX comment) as the prompt. Local session DB evidence: `/full-loop` user messages have one text part starting `<!-- SPDX-License-Identifier: MIT -->`.
2. `.agents/plugins/opencode-aidevops/v1-tui/tui.tsx` opens the timeline on `onMouseDown`. OpenCode's `Dialog` backdrop (`packages/tui/src/ui/dialog.tsx`) closes on `onMouseUp`, so the release of the same click lands on the new full-screen backdrop and dismisses the dialog. Native header controls trigger commands on `onMouseUp`.

## How

- `.agents/plugins/opencode-aidevops/index.mjs`: add a `command.execute.before` hook that stamps the template text part with `metadata.aidevops.command = { name, arguments }` (in-place mutation; model input and native transcript unchanged).
- `.agents/plugins/opencode-aidevops/tui-prompts.mjs`: render stamped parts as `/name arguments`; for legacy/unstamped text strip leading HTML comments and YAML frontmatter before truncation.
- `.agents/plugins/opencode-aidevops/v1-tui/tui.tsx`: dispatch the timeline on `onMouseUp` (V2 renderer already uses `onMouseUp`).

### Files Scope

- .agents/plugins/opencode-aidevops/index.mjs
- .agents/plugins/opencode-aidevops/tui-prompts.mjs
- .agents/plugins/opencode-aidevops/v1-tui/tui.tsx
- .agents/plugins/opencode-aidevops/tests/test-tui-prompts.mjs

## Acceptance

- New `/full-loop foo` turn shows `/full-loop foo` in the sidebar.
- Legacy command turns no longer show SPDX comment headers.
- Clicking a row opens the Timeline dialog and it stays open.
- `node --test .agents/plugins/opencode-aidevops/tests/test-tui-prompts.mjs` passes.

## Verification

`node --test .agents/plugins/opencode-aidevops/tests/test-tui-prompts.mjs`; deploy with `setup.sh --non-interactive`; restart the OpenCode TUI and click a Prompts row.
