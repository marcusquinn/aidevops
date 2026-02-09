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
