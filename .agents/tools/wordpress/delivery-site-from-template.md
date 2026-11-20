---
description: Build a client website from a template site on a WordPress multisite - copy, branding, pages, forms, SEO basics, pre-handover checks
mode: subagent
tools:
  read: true
  bash: true
  edit: true
  write: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Delivery: client site from a template site

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when**: an order or board card asks for a new client website built from a template site on a multisite network.
- **Site-specific source**: the site's board cards (what to do for this client) and the plugin docs (how, per plugin). This doc holds only the cross-site method. Cards win on conflict.
- **Inputs**: network URL, template blog ID, client slug/domain, client brief (business name, services, area, contact details, logo, brand colours, tone), order/card reference.
- **Related**: `wp-cli-reference.md`, `ultimate-multisite.md` (orders, domain mapping), `fluent-mcp.md` (forms, CRM, boards), `rankmath-mcp.md` (SEO), `wp-admin.md`, `wp-multisite-domain-move.md`.

<!-- AI-CONTEXT-END -->

## Rules

- Work on the new blog only; never edit the template blog. Pass `--url=<new-site-url>` on every command.
- Back up first (`wp-dev.md` "Pre-change server backups"). Take a note of the template blog ID and new blog ID.
- Use only content from the client brief. Never invent testimonials, awards, prices, addresses or legal claims; leave a visible card note for anything missing.
- Do not email the client or charge them from this playbook; hand over via the card.

## Steps

1. **Read the card and brief.** List missing inputs on the card; continue with what exists.
2. **Create the site from the template.** Prefer the network's own cloning route (Ultimate Multisite template sites, or the network's site-duplication plugin). Bare WP-CLI fallback: `wp site create --slug=<client-slug> --title="<Business name>" --email=<admin-email>`, then copy template content with `wp export --url=<template>` and `wp import --url=<new> <file> --authors=create`. Confirm: `wp site list --fields=blog_id,url`.
3. **Branding.** `wp option update blogname "<Business name>" --url=<new>`, tagline via `blogdescription`. Set logo and site icon: `wp media import <logo> --porcelain --url=<new>`, then `wp theme mod set custom_logo <id>` and `wp option update site_icon <id>`. Apply brand colours through the theme's global styles or customiser; do not hand-edit theme files.
4. **Copy.** Replace template placeholder text page by page. Find leftovers: `wp db search "<template phrase>" --url=<new> --all-tables-with-prefix`. Update with `wp post update <id> --post_content=...` or search-replace scoped to the new blog's tables (`wp search-replace <old> <new> $(wp db tables --url=<new> --scope=blog) --dry-run` first).
5. **Pages and menus.** Confirm Home, About, Services, Contact, Privacy exist: `wp post list --post_type=page --url=<new> --fields=ID,post_title,post_status`. Rebuild the menu with `wp menu item add-post`. Set `show_on_front`/`page_on_front`.
6. **Forms.** Duplicate the template contact form and point notifications at the client's address (the form plugin's docs give the exact command; for Fluent Forms see `fluent-mcp.md`). Submit one test entry, check it arrives, then delete the test entry.
7. **SEO basics.** Unique title and meta description per page, one H1 per page, image alt text, `blog_public=1` only at launch (`wp option get blog_public --url=<new>`), sitemap loads, local business details and schema from the brief (`rankmath-mcp.md`). Redirect nothing unless the card says so.
8. **Pre-handover checks.**
   - No template text, template business name, template phone/email or template images remain (`wp db search`).
   - `curl -sI <new-url>` returns 200 over HTTPS; every menu link returns 200 (`wp menu item list` then curl).
   - Mobile and desktop screenshots reviewed via `workflows/ui-verification.md`; check contrast, broken images, empty sections.
   - Form test passed, analytics/consent settings match the card, admin user list contains only intended users, `wp plugin list --status=active --url=<new>` matches the template.
9. **Hand over.** Update the card with the URL, what was done, open gaps. Leave domain mapping and billing to `ultimate-multisite.md`.

## Rollback

- New blog only: `wp site deactivate <blog-id>` (reversible), or `wp site delete <blog-id> --yes` after confirmation and a verified backup. Template blog is never touched, so nothing else needs reverting.
- Content mistakes: `wp post revert`/restore from the pre-change export; re-import with `wp import`.
