## What

Add an OpenCode plugin guard so Playwriter can be selected only when the user's own latest message names it. In interactive sessions, block a `task` call with `subagent_type: "playwriter"` and an `aidevops_mcp` call with `{action: "connect", name: "playwriter"}` unless the most recent user message in the root session contains `playwriter` (case-insensitive). The block message must say: "Playwriter (extension relay) is not Playwright. Use subagent_type playwright / @playwright unless the user writes 'Playwriter'."

## Why

GH#35617 (PR #35618) made Playwright the default browser tool and Playwriter explicit-name-only, but only through prompt guidance. The two names differ by a few letters, and a model can auto-correct "Playwright" into "Playwriter" when routing or delegating. That launches the slow relay handoff the operator wants to avoid. `.agents/configs/prompt-hook-candidates.conf` records this as the `Playwright versus Playwriter selection` candidate (status `candidate`).

## How

- Reference pattern: `.agents/plugins/opencode-aidevops/browser-task-transport.mjs` (`assertBrowserTaskTransport`), a `tool.execute.before` Task guard keyed on `args.subagent_type`, wired from `.agents/plugins/opencode-aidevops/index.mjs` (`"tool.execute.before"` near line 741). Tests: `.agents/plugins/opencode-aidevops/tests/test-browser-task-transport.mjs`.
- NEW `.agents/plugins/opencode-aidevops/playwriter-selection-guard.mjs`: export a pure `assertPlaywriterExplicitlyRequested({ tool, args, latestUserText })` and a small resolver for the latest user message text. Inspect how existing plugin code reads session messages before choosing an API. If the latest user text cannot be resolved, fail open (allow) and log once, so a lookup failure does not break explicit Playwriter use.
- Wire it into `index.mjs` `tool.execute.before` beside the browser-task-transport guard. Scope it to `task` and `aidevops_mcp` only. Headless sessions are unaffected: Playwriter is already interactive-only.
- Update `.agents/configs/prompt-hook-candidates.conf`: change the row's STATUS to `partial` (prompt guidance stays for non-OpenCode runtimes) and set ENFORCEMENT to the new module.
- Add focused cases to a new `tests/test-playwriter-selection-guard.mjs` following the `test-browser-task-transport.mjs` style:
  - "use playwright headed" → playwriter Task blocked
  - "connect Playwriter" → allowed
  - playwright Task → untouched
  - non-browser tool → untouched
  - unresolvable user text → allowed

## Acceptance

- A playwriter Task or MCP connect is blocked, with the disambiguation message, when the latest user message lacks "playwriter"; it is allowed when the message contains it.
- `playwright` and all other tools are unaffected.
- `node --test` passes for the new test and the existing `test-browser-task-transport.mjs` and `test-mcp-activation.mjs`.
- The prompt-hook-candidates row is updated, and `.agents/scripts/progressive-load-check.sh` passes.

## Files Scope

- .agents/plugins/opencode-aidevops/playwriter-selection-guard.mjs
- .agents/plugins/opencode-aidevops/index.mjs
- .agents/plugins/opencode-aidevops/tests/test-playwriter-selection-guard.mjs
- .agents/configs/prompt-hook-candidates.conf
