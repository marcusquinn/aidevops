---
name: wordpress
description: WordPress ecosystem management - local development, fleet management, plugin curation
mode: subagent
---

# WordPress - Orchestrator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: WordPress ecosystem management
- **Local Dev**: LocalWP with MCP integration
- **Fleet Management**: MainWP for multi-site operations
- **Preferred Plugins**: See `wp-preferred.md` (127+ plugins)

**Subagents**:
- `wp-dev.md` - Theme/plugin development, debugging
- `wp-admin.md` - Content management, maintenance
- `localwp.md` - Local development with MCP
- `mainwp.md` - Multi-site fleet management
- `wp-preferred.md` - Curated plugin list by category
- `scf.md` - Secure Custom Fields / ACF

**MCP Integration**:
- LocalWP MCP: Direct database access for local sites
- MainWP REST API: Fleet operations

**Key Commands**:

```bash
# LocalWP sites
.agents/scripts/wordpress-mcp-helper.sh list-sites

# MainWP operations
.agents/scripts/mainwp-helper.sh [command] [site]
```

<!-- AI-CONTEXT-END -->

## WordPress Ecosystem

### Local Development

Use LocalWP for local WordPress development:
- Full MCP integration for database access
- See `localwp.md` for setup

### Fleet Management

MainWP provides centralized WordPress management:
- Bulk updates, backups, security scans
- See `mainwp.md` for operations

### Development Workflow

1. **Local**: Develop in LocalWP environment
2. **Test**: Use `wp-dev.md` patterns
3. **Deploy**: Push via MainWP or hosting provider
4. **Manage**: Ongoing via `wp-admin.md`

### Plugin Selection

`wp-preferred.md` contains 127+ curated plugins across 19 categories:
- Performance, Security, SEO
- Forms, E-commerce, Membership
- Backup, Staging, Development tools

Always prefer curated plugins for reliability.

## Oh-My-OpenCode Integration

When oh-my-opencode is installed, leverage these specialized agents for enhanced WordPress development:

| OmO Agent | When to Use | Example |
|-----------|-------------|---------|
| `@frontend-ui-ux-engineer` | Theme UI, Gutenberg blocks, custom components | "Ask @frontend-ui-ux-engineer to create a hero section block" |
| `@oracle` | Architecture decisions, plugin structure, debugging | "Ask @oracle to review this plugin architecture" |
| `@librarian` | WordPress coding standards, hook examples, API patterns | "Ask @librarian for WooCommerce hook examples" |
| `@document-writer` | Plugin documentation, readme files, user guides | "Ask @document-writer to create plugin documentation" |

**Theme Development Workflow**:

```text
1. Design → @frontend-ui-ux-engineer creates UI components
2. Structure → @oracle reviews theme architecture
3. Implement → WordPress agent builds with LocalWP
4. Patterns → @librarian finds WordPress best practices
5. Document → @document-writer creates theme docs
6. Deploy → MainWP pushes to production
```

**Note**: These agents require [oh-my-opencode](https://github.com/code-yeongyu/oh-my-opencode) plugin.
See `tools/opencode/oh-my-opencode.md` for installation.
