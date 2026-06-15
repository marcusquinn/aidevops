---
description: No-build static website starter guidance for plain marketing and documentation sites
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Static Site Starter

Use for plain public sites that need speed, metadata quality, accessibility, and simple hosting without CMS workflows.

## Use no-build static when

- The site is mostly hand-authored landing/docs/marketing content.
- Editors do not need CMS login, revisions, media workflows, or scheduled publishing.
- The page count and repeated layouts are still manageable by hand.
- The deployment target can serve static files directly.

## Use something else when

| Need | Use |
|------|-----|
| Editorial workflow, forms, roles, posts, media library | WordPress |
| Repeated content collections or generated route scale | Static generator after a decision task |
| Auth, dashboards, workflows, user data | TypeScript monorepo app |

## Starter files

| File | Purpose |
|------|---------|
| `index.html` | Semantic structure, metadata, JSON-LD, nav, hero, sections, CTA, footer |
| `about.html` | Required public about/publisher page |
| `contact.html` | Required contact/support/sales page |
| `privacy.html` | Required privacy policy placeholder page |
| `terms.html` | Required terms of service/use placeholder page |
| `docs.html` | Human docs entry point or redirect target |
| `api.html` | API overview or redirect target for generated API docs |
| `mcp.html` | MCP/agent integration overview or redirect target |
| `cli.html` | CLI overview or redirect target |
| `styles.css` | Reset, tokens, layout, responsive components, themes, focus states |
| `script.js` | Progressive enhancement only: theme, tabs, copy feedback, anchors |
| `site.webmanifest` | App name, colours, icons |
| `robots.txt` | Crawl policy and sitemap pointer |
| `sitemap.xml` | Required routes and canonical URLs |
| `README.md` | Customization, validation, deployment notes |

## Metadata checklist

- Title, description, canonical URL, robots, author/publisher.
- Open Graph and Twitter card placeholders.
- Theme colour and app names.
- Favicons and manifest links.
- JSON-LD graph for `WebSite`, `Organization`, and page/app-specific entity.
- JSON-LD/schema for required pages and relevant public objects; see `public-site-surfaces.md`.
- Obvious placeholders for all URLs, images, social accounts, analytics, and product copy.

## Required routes

- `/about`, `/contact`, `/privacy`, and `/terms` are launch blockers for every downstream site.
- `/docs`, `/api`, `/mcp`, and `/cli` should exist as pages, honest status pages, or stable redirects to docs sections.
- Footer and sitemap link to every required page.
- Placeholder legal/contact/developer copy must be visibly marked and replaced before launch.

## Interaction rules

- Prefer native links/buttons/details before custom widgets.
- If tabs are used, implement roving `tabindex`, `ArrowLeft`/`ArrowRight` keys, `Home`/`End`, `aria-selected`, `aria-controls`, and `aria-hidden`.
- Keep JavaScript null-safe and scoped in small modules.
- Update visual state and accessibility state together.
- Theme state may persist locally, but the page must remain readable without JavaScript.

## Verification

- Open locally at desktop and mobile widths.
- Keyboard-test all links, buttons, tabs, copy controls, and theme toggle.
- Check metadata placeholders before launch.
- Verify required public pages, developer pages, sitemap links, and structured data.
- Run accessibility and Lighthouse checks.
- Confirm no site-specific brand, analytics key, secret, internal endpoint, private URL, private repository name, local path, command, non-public support contact, or product copy leaked from a reference site.
