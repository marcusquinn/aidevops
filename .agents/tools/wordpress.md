---
name: wordpress
description: WordPress ecosystem management - local development, fleet management, plugin curation
mode: subagent
---

# WordPress - Orchestrator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Route WordPress work to the right specialist doc
- **Local dev**: LocalWP + `localwp.md`
- **Fleet ops**: MainWP + `mainwp.md`
- **Plugin curation**: `wp-preferred.md` (127+ plugins across 19 categories)
- **Custom fields**: `scf.md` for Secure Custom Fields / ACF

**Subagents**

- `wp-dev.md` — theme/plugin development, debugging, test patterns
- `wp-admin.md` — content management and maintenance
- `localwp.md` — LocalWP development and MCP-backed database access
- `mainwp.md` — multi-site fleet operations via MainWP
- `wp-preferred.md` — curated plugin list by category
- `scf.md` — Secure Custom Fields / ACF guidance

**Platform integrations**

- LocalWP MCP — direct database access for local sites
- MainWP REST API — fleet operations across multiple sites

**Key commands**

```bash
# LocalWP sites
.agents/scripts/wordpress-mcp-helper.sh list-sites

# MainWP operations
.agents/scripts/mainwp-helper.sh [command] [site]
```

<!-- AI-CONTEXT-END -->

## Route by task

| Need | Use | Why |
|------|-----|-----|
| Build or debug code | `wp-dev.md` | Development workflow, debugging, implementation patterns |
| Manage content or routine upkeep | `wp-admin.md` | Admin tasks and site maintenance |
| Inspect a local site or database | `localwp.md` | LocalWP setup and MCP-backed local DB access |
| Update many sites | `mainwp.md` | Centralized MainWP operations |
| Choose plugins | `wp-preferred.md` | Curated, reliability-first recommendations |
| Work with custom fields | `scf.md` | Field modeling and SCF/ACF guidance |

## Operating model

- **Local development**: Use LocalWP for WordPress development and local database access.
- **Fleet management**: Use MainWP for bulk updates, backups, monitoring, and security scans.
- **Plugin selection**: Prefer the curated list in `wp-preferred.md` for reliability.

## Default workflow

1. **Local** — develop in a LocalWP environment.
2. **Test** — follow `wp-dev.md` patterns.
3. **Deploy** — push via MainWP or the hosting provider.
4. **Manage** — handle ongoing operations via `wp-admin.md`.

## Notes

- `wp-preferred.md` covers performance, security, SEO, forms, e-commerce, membership, backup, staging, and development tooling.
- Use this file as the router; keep detailed procedures in the specialist docs.
