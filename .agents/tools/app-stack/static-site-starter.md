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
| `styles.css` | Reset, tokens, layout, responsive components, themes, focus states |
| `script.js` | Progressive enhancement only: theme, tabs, copy feedback, anchors |
| `site.webmanifest` | App name, colours, icons |
| `README.md` | Customization, validation, deployment notes |

## Metadata checklist

- Title, description, canonical URL, robots, author/publisher.
- Open Graph and Twitter card placeholders.
- Theme colour and app names.
- Favicons and manifest links.
- JSON-LD graph for `WebSite`, `Organization`, and page/app-specific entity.
- Obvious placeholders for all URLs, images, social accounts, analytics, and product copy.

## Interaction rules

- Prefer native links/buttons/details before custom widgets.
- If tabs are used, implement roving tabindex, arrow keys, Home/End, `aria-selected`, `aria-controls`, and `aria-hidden`.
- Keep JavaScript null-safe and scoped in small modules.
- Update visual state and accessibility state together.
- Theme state may persist locally, but the page must remain readable without JavaScript.

## Verification

- Open locally at desktop and mobile widths.
- Keyboard-test all links, buttons, tabs, copy controls, and theme toggle.
- Check metadata placeholders before launch.
- Run accessibility and Lighthouse checks.
- Confirm no site-specific brand, analytics key, private URL, command, or product copy leaked from a reference site.
