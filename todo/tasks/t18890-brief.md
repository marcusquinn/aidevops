## What

Add an `aidevops opencode-browse` CLI command that dispatches to `opencode-browse-helper.sh` (merged in PR #37167, GH#37155). Bare `aidevops opencode-browse` shows status. Point user-facing hints and docs at the command instead of the raw helper path.

## Why

Pairing another browser (for example Chrome alongside Brave), listing or revoking paired browsers, and checking relay/extension state are recurring user actions. Today they need `bash ~/.aidevops/agents/scripts/opencode-browse-helper.sh pair`, which users cannot discover from `aidevops help`. The name `opencode-browse` matches the product and the `@opencode-browse` agent and avoids confusion with Playwright (the default browser automation).

## How

- Pattern: one-line helper dispatch in `aidevops.sh` main case (`aidevops.sh:2200-2207`, e.g. `tabby) _dispatch_helper "tabby-helper.sh" ...`). Bare-command default like `inbox` (`aidevops.sh:2182-2186`): `[[ $# -eq 0 ]] && set -- status`.
- Help: add one `aidevops opencode-browse <cmd>` line beside the `tabby`/`knowledge` entries (`aidevops.sh:1309-1312`).
- Replace user-facing `opencode-browse-helper.sh <cmd>` hints with `aidevops opencode-browse <cmd>` in the helper's install/pair messages, `setup/modules/mcp-setup.sh` `setup_opencode_browse()` messages, `tools/browser/opencode-browse.md`, `tools/browser/browser-automation.md`, and the browse activation guidance in `mcp-registry.mjs`. Keep the helper path where it is an execution path (MCP command, setup's helper resolution).
- No alias, no new tests.

### Files Scope

- aidevops.sh
- .agents/scripts/opencode-browse-helper.sh
- .agents/scripts/setup/modules/mcp-setup.sh
- .agents/plugins/opencode-aidevops/mcp-registry.mjs
- .agents/tools/browser/opencode-browse.md
- .agents/tools/browser/browser-automation.md

## Acceptance

- `aidevops opencode-browse` prints browse status; `aidevops opencode-browse pair --list` lists paired browsers; `aidevops help` lists the command.
- Headless refusal still applies (`AIDEVOPS_HEADLESS=1 aidevops opencode-browse pair --list` refuses).

## Verification

- Run the repo `aidevops.sh` from the worktree for the three commands above; `shellcheck` on changed shell files; `markdownlint` on changed docs; plugin MCP registry tests (`node --test .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`).
