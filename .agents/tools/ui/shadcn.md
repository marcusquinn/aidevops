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
- **Registry Docs**: https://ui.shadcn.com/docs/registry/mcp

**When to use**: User asks for UI components; mentions "shadcn", "radix", or component names; project has `components.json` in root.

**MCP tools**: browse registries, search by name/function, install components, work with multiple registries.

**Components**: accordion, alert, alert-dialog, aspect-ratio, avatar, badge, breadcrumb, button, button-group, calendar, card, carousel, chart, checkbox, collapsible, combobox, command, context-menu, data-table, date-picker, dialog, drawer, dropdown-menu, empty, field, form, hover-card, input, input-group, input-otp, item, kbd, label, menubar, native-select, navigation-menu, pagination, popover, progress, radio-group, resizable, scroll-area, select, separator, sheet, sidebar, skeleton, slider, sonner, spinner, switch, table, tabs, textarea, toast, toggle, toggle-group, tooltip, typography

<!-- AI-CONTEXT-END -->

## Setup

Init project (creates `components.json`):

```bash
npx shadcn@latest init
```

### MCP Configuration

MCP server config — key and file path differ per client:

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

## Usage Examples

- "Show me all available components" / "Find a login form" / "What dialog components exist?"
- "Add button, dialog and card components" / "Install form with all dependencies"
- "Create a contact form / landing page / dashboard layout using shadcn components"

## Multiple Registries

Configure in `components.json`:

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

Use namespace syntax: `"Install @internal/auth-form"`. Set auth tokens in `.env.local`.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| MCP not responding | Check config; restart client; `npx shadcn@latest --version`; `/mcp` in Claude Code |
| No tools available | `npx clear-npx-cache`; re-enable server; check logs (Cursor: View → Output → MCP: project-*) |
| Registry access | Verify URLs in `components.json`; check auth env vars |

## Integration with aidevops

1. **Detection**: `components.json` in root = shadcn project
2. **Installation**: use shadcn MCP for component management
3. **Styling**: Tailwind CSS — ensure configured
4. **Forms**: pair with React Hook Form or TanStack Form (see `tools/browser/` for testing)

## Related Resources

- [shadcn/ui Documentation](https://ui.shadcn.com/docs)
- [Component Registry](https://ui.shadcn.com/docs/components)
- [Blocks & Templates](https://ui.shadcn.com/blocks)
- [Theming Guide](https://ui.shadcn.com/docs/theming)
