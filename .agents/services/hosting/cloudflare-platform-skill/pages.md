<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Pages

JAMstack platform for full-stack apps on Cloudflare's global network. Git-based deploys, preview URLs per branch/PR, Pages Functions (Workers runtime), smart asset caching + edge compute. Frameworks: Next.js, SvelteKit, Remix, Astro, Nuxt, Qwik.

## Deployment Methods

**Git Integration (Production):** Dashboard → Workers & Pages → Create → Connect to Git → Configure build

**Direct Upload:**

```bash
npx wrangler pages deploy ./dist --project-name=my-project
npx wrangler pages deploy ./dist --project-name=my-project --branch=staging
```

**C3 CLI:** `npm create cloudflare@latest my-app` — select framework → auto-setup + deploy

## vs Workers

- **Pages**: Static sites, JAMstack, frameworks, git workflow, file-based routing
- **Workers**: Pure APIs, complex routing, WebSockets, scheduled tasks, email handlers
- **Combine**: Pages Functions use Workers runtime, can bind to Workers

## Quick Start

```bash
npm create cloudflare@latest
npx wrangler pages dev ./dist
npx wrangler pages deploy ./dist --project-name=my-project
npx wrangler types --path='./functions/types.d.ts'
echo "value" | npx wrangler pages secret put KEY --project-name=my-project
npx wrangler pages deployment tail --project-name=my-project
```

## Resources

- [Pages Docs](https://developers.cloudflare.com/pages/)
- [Functions API](https://developers.cloudflare.com/pages/functions/api-reference/)
- [Framework Guides](https://developers.cloudflare.com/pages/framework-guides/)
- [Discord #functions](https://discord.com/channels/595317990191398933/910978223968518144)

## See Also

- [patterns.md](./patterns.md) — Full-stack patterns, frameworks
- [gotchas.md](./gotchas.md) — Build issues, limits, debugging
- [pages-functions](../pages-functions/) — File-based routing, middleware
- [d1](../d1/) — SQL database for Pages Functions
- [kv](../kv/) — Key-value storage for caching/state
