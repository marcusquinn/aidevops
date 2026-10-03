# Cloudflare Pages Functions

Use this reference for server-side behavior in an existing Pages project. For new applications, follow the Workers recommendation in the [Pages framework guidance](https://developers.cloudflare.com/pages/framework-guides/index.md).

| Task | Documentation |
| --- | --- |
| Identify filesystem routes and invocation boundaries | [Routing](https://developers.cloudflare.com/pages/functions/routing/index.md) |
| Implement request handlers | [API reference](https://developers.cloudflare.com/pages/functions/api-reference/index.md) |
| Understand generated Worker output | [Advanced mode](https://developers.cloudflare.com/pages/functions/advanced-mode/index.md) |

Inspect whether the project uses a Functions directory or framework-generated advanced mode before selecting a routing approach. Fetch current documentation for signatures, supported bindings, configuration, and examples.

## In This Reference

- [api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/pages-functions/api.md) — handlers, context, middleware, and assets
- [configuration.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/pages-functions/configuration.md) — bindings, environments, types, and local development
- [patterns.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/pages-functions/patterns.md) — request ownership and shared logic
- [gotchas.md](pages-functions-gotchas.md) — route, binding, and runtime investigation

See [Pages](pages.md) for builds and deployment decisions.
