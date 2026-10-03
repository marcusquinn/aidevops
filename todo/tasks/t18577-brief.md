# t18577: feat: add Rank Math MCP support for WordPress SEO

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33175
- **Conversation context:** User asked to add support for Rank Math MCP (<https://rankmath.com/kb/mcp-tools/>) via `/full-loop`.

## What

Add first-class support for the Rank Math SEO MCP tools: the `rank-math/*` WordPress abilities that the Rank Math plugin exposes through the WordPress MCP Adapter default server (`/wp-json/mcp/mcp-adapter-default-server`) and its OAuth server (`/wp-json/mcp/mcp-oauth-server`).

## Why

Rank Math now ships AI-ready abilities: settings and system status, robots.txt/llms.txt, site identity, global/homepage/post-type SEO, links, modules, sitemap, breadcrumbs, site audit and fix, post analysis, schema, SEO meta and scores, links, redirections, link report, Search Console top keywords and AI Visibility. aidevops already documents the generic WordPress MCP Adapter (`tools/wordpress/wp-dev.md`, `scripts/wordpress-mcp-helper.sh`) but has no Rank Math routing, ability catalogue, write-safety rules or credential-safe config generation. The existing `config-http` output also inlines the application password and omits `OAUTH_ENABLED=false`, which Rank Math's documented stdio setup requires.

## How

1. New subagent `.agents/tools/wordpress/rankmath-mcp.md`: prerequisites, auth options (application password via `@automattic/mcp-wordpress-remote`, OAuth remote connector, LocalWP STDIO), ability catalogue with read/write classification and plan requirements, discover → get-info → execute workflow, read-before-write safety, runtime configs, troubleshooting.
2. Extend `.agents/scripts/wordpress-mcp-helper.sh` with `rankmath-config` (OpenCode/Claude JSON that resolves the password from `aidevops secret`/credentials at launch, never inline) and `rankmath-check` (lists `rank-math/*` abilities through the Abilities API REST route).
3. Add `configs/mcp-templates/rankmath.json`.
4. Route from `.agents/tools/wordpress.md`, `.agents/tools/wordpress/wp-dev.md`, `.agents/reference/domain-index.md`, `.agents/subagent-index.toon`, `.agents/aidevops/mcp-integrations.md`.

## Reference pattern

Model on `.agents/services/crm/fluentcrm.md` + `configs/mcp-templates/fluentcrm.json` (per-site WordPress MCP with application password, disabled globally, enabled per subagent).

### Files Scope

- `.agents/tools/wordpress/rankmath-mcp.md`
- `.agents/scripts/wordpress-mcp-helper.sh`
- `configs/mcp-templates/rankmath.json`
- `.agents/tools/wordpress.md`
- `.agents/tools/wordpress/wp-dev.md`
- `.agents/reference/domain-index.md`
- `.agents/subagent-index.toon`
- `.agents/aidevops/mcp-integrations.md`
- `TODO.md`
- `todo/tasks/t18577-brief.md`

## Acceptance criteria

- [ ] `rankmath-mcp.md` documents setup, auth, ability catalogue and write-safety rules.
- [ ] `wordpress-mcp-helper.sh rankmath-config` emits valid JSON with no secret values.
- [ ] `wordpress-mcp-helper.sh rankmath-check` reports `rank-math/*` abilities or a clear failure.
- [ ] WordPress and SEO routing reach the new subagent.

## Verification

```bash
shellcheck .agents/scripts/wordpress-mcp-helper.sh
bash .agents/scripts/wordpress-mcp-helper.sh rankmath-config example https://example.com editor | jq .
bash .agents/scripts/wordpress-mcp-helper.sh help
```
