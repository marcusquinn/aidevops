---
description: shadcn/ui component library MCP for browsing, searching, and installing components
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  shadcn_*: true
mcp:
  - shadcn
---

# shadcn/ui MCP Server

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Browse, search, and install shadcn/ui components via MCP
- **MCP Config**: `configs/mcp-templates/shadcn.json`
- **Docs**: https://ui.shadcn.com/docs/mcp

**When to use**: User asks for UI components; mentions "shadcn", "radix", or component names; project has `components.json` in root.

**MCP tools**: browse registries, search by name/function, install components, work with multiple registries. Use the MCP browse tool to list available components (do not rely on a static list).

<!-- AI-CONTEXT-END -->

## Setup

Init project (creates `components.json`): `npx shadcn@latest init`

### MCP Configuration

Config key and file path differ per client:

| Client | Config file | Key |
|--------|-------------|-----|
| Claude Code | `.mcp.json` | `mcpServers` |
| Cursor | `.cursor/mcp.json` | `mcpServers` |
| VS Code | `.vscode/mcp.json` | `servers` |
| OpenCode | `~/.config/opencode/opencode.json` | `mcp` |

```json
{
  "shadcn": {
    "command": "npx",
    "args": ["shadcn@latest", "mcp"]
  }
}
```

## Multiple Registries

Add to `components.json`. Use namespace syntax (`@acme/component-name`). Set auth tokens in `.env.local`.

```json
{
  "registries": {
    "@acme": "https://registry.acme.com/{name}.json",
    "@internal": {
      "url": "https://internal.company.com/{name}.json",
      "headers": { "Authorization": "Bearer ${REGISTRY_TOKEN}" }
    }
  }
}
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| MCP not responding | Check config; restart client; `npx shadcn@latest --version`; `/mcp` in Claude Code |
| No tools available | `npx clear-npx-cache`; re-enable server; check logs (Cursor: View -> Output -> MCP: project-*) |
| Registry access | Verify URLs in `components.json`; check auth env vars |

## Integration with aidevops

1. **Detection**: `components.json` in root = shadcn project
2. **Installation**: use shadcn MCP for component management
3. **Styling**: Tailwind CSS -- ensure configured
4. **Forms**: pair with React Hook Form or TanStack Form (see `tools/browser/` for testing)
