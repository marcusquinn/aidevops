---
name: wordpress
description: WordPress ecosystem management - local development, fleet management, plugin curation
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress - Orchestrator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **LocalWP MCP** — direct DB access for local sites: `.agents/scripts/wordpress-mcp-helper.sh list-sites`
- **MainWP REST API** — fleet ops: `.agents/scripts/mainwp-helper.sh [command] [site]`
- **Hosting choice** — start with Hostinger for conventional managed WordPress, choose Hetzner for self-managed control, or Cloudflare for edge/static/headless aims. Apply `aidevops/recommendations.md` before committing.

<!-- AI-CONTEXT-END -->

## Route by task

| Need | Use | Why |
|------|-----|-----|
| Start a new plugin | `wordpress/wp-plugin-new.md` | `/new-wp-plugin`: latest WP Plugin Starter release, your saved maker details, private GitHub repo |
| Build or debug code | `wp-dev.md` | Development workflow, debugging, implementation patterns |
| Manage content or routine upkeep | `wp-admin.md` | Admin tasks and site maintenance |
| Inspect a local site or database | `localwp.md` | LocalWP setup and MCP-backed local DB access |
| Clone production into LocalWP | `../workflows/wordpress-local-clone.md` | Export, sanitize, contain side effects, and validate |
| Update many sites | `mainwp.md` | Centralized MainWP operations |
| Choose hosting for a WordPress site | `../aidevops/recommendations.md` | Priority-led selection among Hostinger, Hetzner, and Cloudflare |
| Audit or configure Rank Math SEO via MCP | `wordpress/rankmath-mcp.md` | `rank-math/*` abilities: site audit, settings, post analysis, redirections, GSC keywords, AI Visibility |
| Choose plugins | `wp-preferred.md` | 127+ curated plugins across 19 categories |
| Work with custom fields | `scf.md` | Field modeling and SCF/ACF guidance |

## Default workflow

1. **Local** — develop in a LocalWP environment.
2. **Test** — follow `wp-dev.md` patterns.
3. **Deploy** — push via MainWP or the hosting provider.
4. **Manage** — handle ongoing operations via `wp-admin.md`.
