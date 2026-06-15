---
description: Required public pages, structured data, docs/API/MCP/CLI surfaces, and discoverability standards for websites and apps
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Public Site Surfaces and Schema

Every public website and app needs trustworthy public surfaces before launch. Treat legal, contact, docs, developer, agent, and structured-data pages as product infrastructure.

## Required public pages

| Route | Purpose |
|-------|---------|
| `/about` | Who operates the site/app, mission, audience, provenance, ownership/publisher details |
| `/contact` | Support/sales/general contact channels, postal/company details when relevant, response expectations |
| `/privacy` | Privacy policy, data collection, cookies/analytics, retention, processors, user rights |
| `/terms` | Terms of service/use, acceptable use, liability, jurisdiction, billing/subscription terms when relevant |

Rules:

- Required pages must be linked from the footer and sitemap, not hidden in app chrome.
- Use stable canonical URLs; redirects preserve old legal/support URLs.
- Keep legal pages editable and versionable; record effective date, last updated date, and policy owner.
- Apps that require login still need public versions of these pages outside the authenticated shell.
- Small no-build/static sites can ship placeholder pages, but placeholders must be obvious and replaced before launch.

## Structured data and schema

| Surface | Structured data default |
|---------|-------------------------|
| Site/app home | `WebSite`, `Organization` or `Person`, app/product/service entity as relevant |
| About page | `AboutPage`, publisher/person/organization details |
| Contact page | `ContactPage`, contact points, area served, support channels |
| Privacy page | Valid `WebPage`/`CreativeWork` policy metadata with publisher, dates, canonical URL; do not invent unsupported types |
| Terms page | Valid `WebPage`/`CreativeWork` terms metadata with publisher, dates, canonical URL; do not invent unsupported types |
| Docs/API/MCP/CLI pages | `WebPage`, `TechArticle`, `SoftwareApplication`, `HowTo`, or another validator-supported schema.org type |
| Content/entity pages | Domain-specific schema for products, articles, events, FAQs, reviews, courses, jobs, places, datasets, or software |

Rules:

- Prefer JSON-LD in the page head or near the relevant content; keep it consistent with visible page content.
- Use stable `@id` values tied to canonical URLs and avoid duplicate/conflicting entities.
- Model breadcrumbs with `BreadcrumbList` when pages are nested.
- Include publisher, logo/image, canonical URL, language, dates, and contact points where relevant.
- Validate structured data before launch and after template changes.
- Do not add schema for facts that are not visible, accurate, or supportable.

## Documentation surface

| Surface | Use |
|---------|-----|
| `/docs` | Default human documentation entry for small/medium apps and static sites |
| `docs.` subdomain | Larger docs with versioning, search, generated references, or separate deploy cadence |
| `/docs/api` | API overview when API reference is part of docs |
| `/docs/cli` | CLI documentation when CLI docs are part of docs |
| `/docs/mcp` | MCP/server documentation when agent docs are part of docs |

Rules:

- Every app should have a human-readable docs entry point, even if it starts as a short overview.
- Choose `/docs` until docs need independent hosting, versioning, search, or contributor workflow.
- Docs need getting started, concepts, auth/setup, examples, troubleshooting, changelog, and support links.
- Documentation should link to terms, privacy, contact, API, MCP, CLI, status/support, and release notes when those exist.

## API, MCP, and CLI surfaces

| Route | Purpose |
|-------|---------|
| `/api` | Human API overview: status, auth model, base URLs, versioning, rate limits, SDKs, OpenAPI/reference links |
| `api.` subdomain | Machine/API endpoint host when separated from the web app |
| `/mcp` | Human MCP overview: server URL, auth/scopes, tool catalog, schemas, safety model, examples |
| `/cli` | Human CLI overview: install, authentication, command groups, examples, update/uninstall, support |

Rules:

- `/api`, `/mcp`, and `/cli` can redirect to docs sections for small products, but the routes should remain stable and discoverable.
- If an API, MCP server, or CLI is not yet public, the route should honestly say so or redirect to the roadmap/support page; never imply a non-existent integration works.
- Generate API reference from OpenAPI/RPC metadata when possible; hand-written pages explain concepts, auth, examples, and support.
- MCP and CLI integrations use the same service contracts, auth, permissions, audit, rate limits, and idempotency rules as the API.
- Agent-facing pages should include safe example prompts/commands, data-access scopes, destructive-operation warnings, and support/contact routes.
- Publish machine-readable discovery only when maintained: OpenAPI document, SDK package metadata, MCP server/tool schema, CLI release metadata, and optional `llms.txt` / agent docs index.
- Never publish secrets, internal endpoints, private repository names, local paths, or non-public support contacts.

## Verification

- Visit `/about`, `/contact`, `/privacy`, `/terms`, `/docs`, `/api`, `/mcp`, and `/cli` or their documented redirects/status pages.
- Confirm footer, sitemap, robots policy, canonical URLs, and redirects expose required pages.
- Validate JSON-LD/schema for home, required pages, docs/API/developer pages, and one domain object page.
- Confirm API/MCP/CLI pages match implemented auth, scopes, endpoints, tools, and support policy.
- Confirm no placeholder legal/contact/API data remains before launch.
