---
mode: subagent
---
# t1288: Add OpenAPI Search MCP integration — janwilmake/openapi-mcp-server (875 stars, MIT) lets LLMs search/explore OpenAPI specs via 3-step process (find API, get summary, drill into endpoints). Use remote MCP at `https://openapi-mcp.openapisearch.com/mcp` (zero install, Cloudflare Worker). Create subagent, config templates, wire into agent generation. Follow `add-new-mcp-to-aidevops.md` checklist. Links: https://openapisearch.com/ https://github.com/janwilmake/openapi-mcp-server

## Origin

- **Created:** 2026-02-21
- **Session:** supervisor:pid:78731 (headless Claude CLI)
- **Created by:** ai-supervisor

- **Commit:** 54e25ac481f1fb5e6200e1190c8225484cd099b7 — "chore: claim t1294.1 by assignee:marcusquinn"

## What

Add OpenAPI Search MCP integration — janwilmake/openapi-mcp-server (875 stars, MIT) lets LLMs search/explore OpenAPI specs via 3-step process (find API, get summary, drill into endpoints). Use remote MCP at `https://openapi-mcp.openapisearch.com/mcp` (zero install, Cloudflare Worker). Create subagent, config templates, wire into agent generation. Follow `add-new-mcp-to-aidevops.md` checklist. Links: https://openapisearch.com/ https://github.com/janwilmake/openapi-mcp-server

## Specification

```markdown
- [ ] t1288 Add OpenAPI Search MCP integration — janwilmake/openapi-mcp-server (875 stars, MIT) lets LLMs search/explore OpenAPI specs via 3-step process (find API, get summary, drill into endpoints). Use remote MCP at `https://openapi-mcp.openapisearch.com/mcp` (zero install, Cloudflare Worker). Create subagent, config templates, wire into agent generation. Follow `add-new-mcp-to-aidevops.md` checklist. Links: https://openapisearch.com/ https://github.com/janwilmake/openapi-mcp-server #feature #mcp #agent #auto-dispatch ~2h (ai:1.5h test:30m) model:sonnet assignee:marcusquinn started:2026-02-21T04:08:03Z ref:GH#2057 logged:2026-02-21 → [todo/PLANS.md#2026-02-21-openapi-search-mcp-integration]
  - [x] t1288.1 Create subagent doc `.agents/tools/context/openapi-search.md` — frontmatter with `openapi-search_*: true`, AI-CONTEXT-START block, tool descriptions (searchAPIs, getAPIOverview, getOperationDetails), usage examples, verification prompt. Follow context7.md pattern. #auto-dispatch ~30m model:sonnet assignee:marcusquinn started:2026-02-21T04:08:11Z ref:GH#2069 pr:#2076 completed:2026-02-21
  - [x] t1288.2 Create config templates `configs/openapi-search-config.json.txt` and `configs/mcp-templates/openapi-search.json` — remote MCP URL config for all supported AI assistants (OpenCode, Claude Code, Cursor, Gemini CLI, etc.). No API key required. #auto-dispatch ~20m model:sonnet ref:GH#2070 assignee:marcusquinn started:2026-02-21T06:53:50Z pr:#2090 completed:2026-02-21
  - [x] t1288.3 Update `generate-opencode-agents.sh` — add `openapi-search` MCP (disabled globally), enable `openapi-search_*: true` for Build+, AI-DevOps, Research agents only. #auto-dispatch ~15m model:sonnet ref:GH#2071 assignee:marcusquinn started:2026-02-21T07:33:20Z pr:#2094 completed:2026-02-21
  - [x] t1288.4 Update `ai-cli-config.sh` — add `configure_openapi_search_mcp()` function for all detected AI assistants. Remote URL, no prerequisites. #auto-dispatch ~15m model:sonnet ref:GH#2072 assignee:marcusquinn started:2026-02-21T07:52:38Z pr:#2095 completed:2026-02-21
  - [x] t1288.5 Update `mcp-integrations.md` and `subagent-index.toon` — add OpenAPI Search to MCP integrations doc and register in subagent index. #auto-dispatch ~15m model:sonnet ref:GH#2073 assignee:marcusquinn started:2026-02-21T07:14:09Z pr:#2092 completed:2026-02-21
  - [ ] t1288.6 Test and verify — run `generate-opencode-agents.sh`, verify MCP appears in config, test with verification prompt ("Search for the Stripe API and show me the create payment intent endpoint"). #auto-dispatch ~15m model:sonnet ref:GH#2074 assignee:marcusquinn started:2026-02-21T08:08:43Z
```



## Supervisor Context

```
t1288|Add OpenAPI Search MCP integration — janwilmake/openapi-mcp-server (875 stars, MIT) lets LLMs search/explore OpenAPI specs via 3-step process (find API, get summary, drill into endpoints). Use remote MCP at `https://openapi-mcp.openapisearch.com/mcp` (zero install, Cloudflare Worker). Create subagent, config templates, wire into agent generation. Follow `add-new-mcp-to-aidevops.md` checklist. Links: https://openapisearch.com/ https://github.com/janwilmake/openapi-mcp-server #feature #mcp #agent #auto-dispatch ~2h (ai:1.5h test:30m) model:sonnet logged:2026-02-21 → [todo/PLANS.md#2026-02-21-openapi-search-mcp-integration]|pid:78731|2026-02-21T04:06:34Z|2026-02-21T05:32:43Z
```

## Acceptance Criteria

- [ ] Implementation matches the specification above
- [ ] Tests pass
- [ ] Lint clean

## Relevant Files

<!-- TODO: Add relevant file paths after codebase analysis -->
