# Workers Static Assets

Use Workers Static Assets for new static sites, SPAs, generated sites, and applications combining assets with server logic. Inspect the framework, build output, and existing deployment configuration before changing routing.

| Task | Documentation |
|------|---------------|
| Set up and deploy a static site or application | [Get started](https://developers.cloudflare.com/workers/static-assets/get-started/index.md) |
| Choose configuration and an optional asset binding | [Configuration and bindings](https://developers.cloudflare.com/workers/static-assets/binding/index.md) |
| Serve a client-rendered application | [SPA routing](https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/index.md) |
| Serve generated HTML and custom error pages | [SSG routing](https://developers.cloudflare.com/workers/static-assets/routing/static-site-generation/index.md) |
| Use a full-stack framework | [Full-stack application guides](https://developers.cloudflare.com/workers/static-assets/routing/full-stack-application/index.md) |
| Evaluate moving an existing Pages project | [Pages migration guide](https://developers.cloudflare.com/workers/static-assets/migration-guides/migrate-from-pages/index.md) |

Do not choose a platform solely from the framework name. For an existing Pages project, inspect its current features and migration requirements before proposing a move.

## Reading Order

1. [configuration.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/static-assets/configuration.md) — build output and routing configuration.
2. [api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/static-assets/api.md) — fetch assets and handle responses.
3. [patterns.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/static-assets/patterns.md) — choose a routing design.
4. [gotchas.md](static-assets-gotchas.md) — diagnose routing, caching, and deployment issues.
