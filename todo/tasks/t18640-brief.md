# Add SEO Utils MCP support (on-demand `@seo-utils`)

## Origin

- Created: 2026-10-09, interactive session (ai-interactive), requested by maintainer:
  "add seoutils-mcp support to aidevops ... same implementation as other mcps we have".
- Sources: https://help.seoutils.app/guide/mcp-server, https://github.com/seoutilsapp/seo-utils-skills

## What

Register the SEO Utils desktop app's local stdio MCP server the same way as other
on-demand MCPs (PostHog, DataForSEO, Backblaze B2): globally disabled, connected by
a bounded `@seo-utils` agent through `aidevops_mcp`, with routing and safety guidance.

## Why

SEO Utils stores the user's own rank trackers, long-range Search Console history,
GA4, GMB grids, LLM visibility and log analysis locally. Agents should read that data
for free instead of buying third-party estimates, and must not run paid lookups or
state-changing actions without approval.

## How

### Files to Modify

- NEW: `.agents/scripts/seo-utils-mcp-launcher.sh` — resolve the app executable
  (macOS default paths or `SEO_UTILS_BIN`), refuse builds without `mcp-stdio`
  (2.5.0 and earlier start the full backend instead), `exec <bin> mcp-stdio`.
- EDIT: `.agents/plugins/opencode-aidevops/mcp-registry.mjs` — `seo-utils` entry
  (lazy, 15 min `timeout`, activation guidance); generated local entries carry `timeout`.
- EDIT: `.agents/plugins/opencode-aidevops/agent-mcp-tools.mjs`, `.agents/scripts/lib/mcp_config.py` — tool pattern and lazy set.
- NEW: `.agents/seo/seo-utils.md` — agent: tool model, local-data-first routing, workspaces, spend and write safety, setup, troubleshooting.
- NEW: `configs/mcp-templates/seo-utils.json` — OpenCode, Claude Code, Codex, mcpServers templates.
- EDIT: `.agents/seo.md`, `.agents/reference/domain-index.md`, `.agents/aidevops/mcp-integrations.md`,
  `.agents/subagent-index.toon`, `.agents/configs/capability-registry.json`, `.agents/configs/allowed-urls.txt`.

### Verification

- `shellcheck .agents/scripts/seo-utils-mcp-launcher.sh`; launcher dry-run, missing-binary and old-build refusals; stub binary receives `mcp-stdio`.
- `node --test .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs`.
- Registry probe: entry disabled with timeout, user-owned entry preserved but disabled, `@seo-utils` profile has `seo-utils_*` + `aidevops_mcp`.
- `capability-readiness-helper.py check`; markdownlint on changed docs.

## Acceptance Criteria

- [x] `seo-utils` MCP registered globally disabled; only `@seo-utils` gets `seo-utils_*` tools.
- [x] Launcher fails closed on missing app or a build without `mcp-stdio`.
- [x] Generated and template entries set a 900000 ms timeout.
- [x] Agent doc distinguishes free reads, credit-spending lookups and approval-gated writes.
- [ ] Live handshake against an SEO Utils build newer than 2.5.0 (installed build is 2.5.0 or earlier; launcher refuses it).
