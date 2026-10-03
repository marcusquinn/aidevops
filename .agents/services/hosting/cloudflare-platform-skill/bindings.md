# Cloudflare Workers Bindings

Bindings grant a Worker access to configured resources through its environment. Prefer a product's binding for supported operations inside Workers; use the REST API when the caller or operation requires it.

Read the relevant current documentation before implementing. These references route to maintained APIs and configuration rather than copying binding catalogs, type tables, or limits.

## Start here

- [Bindings overview and catalog](https://developers.cloudflare.com/workers/runtime-apis/bindings/index.md): capability model, available products, environment access, and binding lifecycle.
- [Storage options](https://developers.cloudflare.com/workers/platform/storage-options/index.md): choose storage from consistency, query, and coordination requirements.
- [api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/bindings/api.md): environment access, generated types, and product APIs.
- [configuration.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/bindings/configuration.md): binding configuration, environments, secrets, and local development.
- [patterns.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/bindings/patterns.md): Worker-to-Worker calls, testing, and resource selection.
- [gotchas.md](bindings-gotchas.md): missing bindings, stale clients, development differences, and limits.

Treat each binding as a capability granted to code. Select only the resources the Worker needs, and confirm which environment and resource each binding targets before using it.
