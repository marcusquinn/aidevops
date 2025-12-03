# WordPress - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: WordPress ecosystem management
- **Local Dev**: LocalWP with MCP integration
- **Fleet Management**: MainWP for multi-site operations
- **Preferred Plugins**: See `wordpress/wp-preferred.md` (127+ plugins)

**Subagents** (`wordpress/`):
- `wp-dev.md` - Theme/plugin development, debugging
- `wp-admin.md` - Content management, maintenance
- `localwp.md` - Local development with MCP
- `mainwp.md` - Multi-site fleet management
- `wp-preferred.md` - Curated plugin list by category

**MCP Integration**:
- LocalWP MCP: Direct database access for local sites
- MainWP REST API: Fleet operations

**Key Commands**:

```bash
# LocalWP sites
.agent/scripts/wordpress-mcp-helper.sh list-sites

# MainWP operations
.agent/scripts/mainwp-helper.sh [command] [site]
```

<!-- AI-CONTEXT-END -->

## WordPress Ecosystem

### Local Development

Use LocalWP for local WordPress development:
- Full MCP integration for database access
- See `wordpress/localwp.md` for setup

### Fleet Management

MainWP provides centralized WordPress management:
- Bulk updates, backups, security scans
- See `wordpress/mainwp.md` for operations

### Development Workflow

1. **Local**: Develop in LocalWP environment
2. **Test**: Use `wordpress/wp-dev.md` patterns
3. **Deploy**: Push via MainWP or hosting provider
4. **Manage**: Ongoing via `wordpress/wp-admin.md`

### Plugin Selection

`wordpress/wp-preferred.md` contains 127+ curated plugins across 19 categories:
- Performance, Security, SEO
- Forms, E-commerce, Membership
- Backup, Staging, Development tools

Always prefer curated plugins for reliability.
