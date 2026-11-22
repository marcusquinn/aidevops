## What

Add first-class support for OpenCode browse (the `browse` CLI + Chrome Web Store extension `mfnicocicmmlkpjnaffgihfjhdgjkdjg`, installer `https://opencode.ai/browse/install`). It drives the user's existing Chromium-family browser through deterministic Playwright code, with handoffs, site-secret typing, allowlists, recordings and network capture.

## Why

aidevops currently tells agents that the user's everyday logged-in tab cannot be driven and routes to a dedicated-profile CDP launch. browse is an officially supported, extension-paired route into the user's real browser with explicit tab lending, per-session allowlists and human handoffs. Setup/update should install it automatically where a supported browser exists.

## How

Evidence from `browse` 0.0.15 (`browse --help`, `browse skill`, isolated-HOME probe of `browse install`):

- Installer `--no-setup` downloads a checksum-verified binary to `${XDG_BIN_HOME:-~/.local/bin}/browse`; `browse install --no-open --no-wait -a <agent|none>` configures agents and pairing; `browse mcp` is the stdio MCP server.
- Paths follow `XDG_{CONFIG,DATA,STATE,CACHE}_HOME/browse`. aidevops OpenCode sessions redirect `XDG_DATA_HOME` per project, so the relay token (`$XDG_DATA_HOME/browse/relay-token`) would differ per project. Precedent for dropping the redirect: `.agents/scripts/localdev-helper-init.sh` `run_stable_mkcert`.

Files:

- NEW `.agents/scripts/opencode-browse-helper.sh` — `detect` (supported Chromium browsers), `install` (verified download, `--no-setup`, then `browse install -a none --no-modify-path`), `status`, `mcp` (launcher: drop aidevops per-session `XDG_DATA_HOME`, refuse headless/worker runtimes), `run -- <args>` (same stable env for CLI use).
- EDIT `.agents/scripts/setup/modules/mcp-setup.sh` — `_setup_browser_tools_opencode_browse` from `setup_browser_tools`; install/update when a supported browser is detected; print Web Store + pairing steps.
- EDIT `.agents/plugins/opencode-aidevops/mcp-registry.mjs` — lazy `browse` registry entry (activation agent `opencode-browse`, `browse_*` tools) using the helper launcher; model on the `chrome-devtools`/`playwright` entries.
- EDIT `.agents/plugins/opencode-aidevops/agent-mcp-tools.mjs`, `.agents/scripts/generate-opencode-agents.sh`, `.agents/scripts/generate-runtime-config-agents.sh`, `.agents/scripts/lib/mcp_config.py` (`LAZY_MCPS`).
- NEW `.agents/tools/browser/opencode-browse.md`; EDIT `.agents/tools/browser/browser-automation.md` decision tree ("use my logged-in tab"), `.agents/subagent-index.toon`.

### Files Scope

- .agents/scripts/opencode-browse-helper.sh
- .agents/scripts/setup/modules/mcp-setup.sh
- setup.sh
- .agents/plugins/opencode-aidevops/mcp-registry.mjs
- .agents/plugins/opencode-aidevops/agent-mcp-tools.mjs
- .agents/scripts/generate-opencode-agents.sh
- .agents/scripts/generate-runtime-config-agents.sh
- .agents/scripts/lib/mcp_config.py
- .agents/tools/browser/opencode-browse.md
- .agents/tools/browser/browser-automation.md
- .agents/subagent-index.toon

## Acceptance

- `aidevops update`/`setup.sh --non-interactive` installs or refreshes `browse` when Chrome/Edge/Brave/Arc/Chromium/Vivaldi is present, never blocks waiting for pairing, and skips cleanly otherwise.
- OpenCode exposes `browse` via `aidevops_mcp connect browse` / `@opencode-browse` without eager loading.
- One relay token is shared across projects (launcher drops the per-session `XDG_DATA_HOME`).
- Headless/worker runtimes cannot drive the user's browser through the launcher.
- Docs route "use my real/logged-in browser tab" to browse when installed and paired; Playwright remains the default.

## Verification

- `shellcheck .agents/scripts/opencode-browse-helper.sh .agents/scripts/setup/modules/mcp-setup.sh`
- `node --test .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`
- `opencode-browse-helper.sh status` and a live `opencode-browse-helper.sh run -- execute --rm 'return 1+1'` against a paired Chrome.
