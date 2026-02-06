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
---

# shadcn/ui MCP Server

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Browse, search, and install shadcn/ui components via MCP
- **MCP Config**: `configs/mcp-templates/shadcn.json`
- **Docs**: https://ui.shadcn.com/docs/mcp
- **Registry Docs**: https://ui.shadcn.com/docs/registry/mcp

**When to use this MCP**:
- User asks to add UI components (buttons, dialogs, forms, cards, etc.)
- Building landing pages, dashboards, or forms
- User mentions "shadcn", "radix", or component names like "dialog", "sheet", "toast"
- Project has `components.json` in root (shadcn-initialized project)

**Available Tools** (via MCP):
- Browse all components in registries
- Search for specific components by name/functionality
- Install components directly into project
- Work with multiple registries (public, private, third-party)

**Components Available**: accordion, alert, alert-dialog, aspect-ratio, avatar, badge, breadcrumb, button, button-group, calendar, card, carousel, chart, checkbox, collapsible, combobox, command, context-menu, data-table, date-picker, dialog, drawer, dropdown-menu, empty, field, form, hover-card, input, input-group, input-otp, item, kbd, label, menubar, native-select, navigation-menu, pagination, popover, progress, radio-group, resizable, scroll-area, select, separator, sheet, sidebar, skeleton, slider, sonner, spinner, switch, table, tabs, textarea, toast, toggle, toggle-group, tooltip, typography

<!-- AI-CONTEXT-END -->

## Setup

### Prerequisites

1. Project must be initialized with shadcn:

   ```bash
   npx shadcn@latest init
   ```

2. This creates `components.json` in project root

### MCP Configuration

Add to your MCP client config:

**Claude Code** (`.mcp.json`):

```json
{
  "mcpServers": {
    "shadcn": {
      "command": "npx",
      "args": ["shadcn@latest", "mcp"]
    }
  }
}
```

**Cursor** (`.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "shadcn": {
      "command": "npx",
      "args": ["shadcn@latest", "mcp"]
    }
  }
}
```

**VS Code** (`.vscode/mcp.json`):

```json
{
  "servers": {
    "shadcn": {
      "command": "npx",
      "args": ["shadcn@latest", "mcp"]
    }
  }
}
```

**OpenCode** (`~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
    "shadcn": {
      "command": "npx",
      "args": ["shadcn@latest", "mcp"]
    }
  }
}
```

## Usage Examples

### Browse & Search

- "Show me all available components in the shadcn registry"
- "Find me a login form from the shadcn registry"
- "What dialog components are available?"

### Install Components

- "Add the button, dialog and card components to my project"
- "Install the form component with all its dependencies"
- "Add a date picker to my project"

### Build with Components

- "Create a contact form using components from the shadcn registry"
- "Build a landing page using hero, features and testimonials sections"
- "Create a dashboard layout with sidebar navigation"

## Multiple Registries

Configure additional registries in `components.json`:

```json
{
  "registries": {
    "@acme": "https://registry.acme.com/{name}.json",
    "@internal": {
      "url": "https://internal.company.com/{name}.json",
      "headers": {
        "Authorization": "Bearer ${REGISTRY_TOKEN}"
      }
    }
  }
}
```

Then use namespace syntax:
- "Show me components from acme registry"
- "Install @internal/auth-form"

## Private Registry Authentication

Set environment variables in `.env.local`:

```bash
REGISTRY_TOKEN=your_token_here
API_KEY=your_api_key_here
```

## Troubleshooting

### MCP Not Responding

1. Check configuration is correct
2. Restart your MCP client
3. Verify `shadcn` is accessible: `npx shadcn@latest --version`
4. Use `/mcp` command in Claude Code to debug

### No Tools Available

1. Clear npx cache: `npx clear-npx-cache`
2. Re-enable the MCP server
3. Check logs (Cursor: View -> Output -> MCP: project-*)

### Registry Access Issues

1. Verify registry URLs in `components.json`
2. Check authentication environment variables
3. Test registry accessibility directly

## Integration with aidevops

When working on React/Next.js projects:

1. **Detection**: Check for `components.json` to identify shadcn projects
2. **Component Installation**: Use shadcn MCP for component management
3. **Styling**: Components use Tailwind CSS - ensure it's configured
4. **Forms**: Use with React Hook Form or TanStack Form (see `tools/browser/` for form testing)

## Related Resources

- [shadcn/ui Documentation](https://ui.shadcn.com/docs)
- [Component Registry](https://ui.shadcn.com/docs/components)
- [Blocks & Templates](https://ui.shadcn.com/blocks)
- [Theming Guide](https://ui.shadcn.com/docs/theming)
