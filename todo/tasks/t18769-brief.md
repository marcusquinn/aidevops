## What

Make the browser-automation preference explicit and enforceable:

1. Playwright is the default for all browser work, in one of three modes: headless (default), headed, or **headed-hidden** (new).
2. Playwriter is used only when the user names "Playwriter" explicitly.
3. Every routing surface states that Playwright and Playwriter are different tools, so a model must not auto-correct one name into the other.

## Why

The operator finds Playwriter slow to start and use (selected-tab relay handoff, GH#35516) and prefers Playwright. The two names differ by a few letters, which risks a model substituting one for the other when routing or delegating. "Headed but hidden" is not available today: `AIDEVOPS_PLAYWRIGHT_HEADED=1` opens a visible window.

Probe evidence (2026-10-25, macOS, Brave, playwright-core 1.64.1):

- `--window-position=-32000,-32000` does not hide the window on macOS; it was clamped onto a secondary display (`left: -1728`), and Brave took focus.
- CDP `Browser.setWindowBounds {windowState: "minimized"}` per page keeps the browser headed and fully working: rAF ran at 60 fps, `visibilityState` stayed `visible`, the UA was not headless, and screenshots (41 ms), clicks, and a second page all worked.
- Launch can take focus depending on the user's activity. `lsappinfo setfront` returns `permErr`; LaunchServices `open -b <bundle-id>` needs no extra permission. Restoring focus must be guarded so it runs only when the frontmost app is the MCP's own browser child process (one run showed the user's app still in front).

## How

- `.agents/plugins/opencode-aidevops/mcp-registry.mjs`: in `playwrightMcpCommand()`, accept `AIDEVOPS_PLAYWRIGHT_HEADED=hidden`. It drops `--headless` and adds `--init-page <scripts/playwright-headed-hidden-init.cjs>`. Headless-runtime markers still force headless. Update the `playwright` and `playwriter` descriptions/guidance to name the tools explicitly.
- NEW `.agents/scripts/playwright-headed-hidden-init.cjs`: a Playwright MCP init-page hook that minimises each page window through CDP, then restores focus on macOS only if the browser is the frontmost app. It never throws.
- `.agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`: extend the headed test with the hidden mode.
- Docs: `tools/browser/browser-automation.md`, `tools/browser/playwright.md`, `tools/browser/playwriter.md`, `build-plus.md` (Domain Expertise row), `reference/agent-routing.md`, `configs/prompt-hook-candidates.conf` (Task guard candidate).

## Acceptance

- `AIDEVOPS_PLAYWRIGHT_HEADED=hidden` generates an MCP command without `--headless` and with `--init-page`; worker/CI markers still produce `--headless`.
- A live `@playwright/mcp@0.0.79` run in hidden mode navigates and snapshots a page, and its window ends minimised.
- Playwright vs Playwriter disambiguation appears in browser-automation, playwright, playwriter, build-plus, agent-routing and both MCP registry descriptions.
- `node --test .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs` and markdownlint pass.

## Files Scope

- .agents/plugins/opencode-aidevops/mcp-registry.mjs
- .agents/scripts/playwright-headed-hidden-init.cjs
- .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs
- .agents/tools/browser/browser-automation.md
- .agents/tools/browser/playwright.md
- .agents/tools/browser/playwriter.md
- .agents/build-plus.md
- .agents/reference/agent-routing.md
- .agents/configs/prompt-hook-candidates.conf
- .agents/tools/context/mcp-discovery.md
