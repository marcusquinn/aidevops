# Cloudflare Wrangler

Primary CLI for Cloudflare Workers: scaffold projects, run local/remote dev, manage bindings, deploy, and inspect versions.

## Install

```bash
npm install -D wrangler   # dev dependency (npx wrangler <cmd>)
npm install -g wrangler   # global
```

## Core Commands

```bash
wrangler init [name]                  # Create project
wrangler dev                          # Local dev server
wrangler dev --remote                 # Remote dev with real bindings
wrangler deploy                       # Deploy production
wrangler deploy --env staging         # Deploy named environment
wrangler versions list                # List deployed versions
wrangler rollback [id]                # Roll back deployment
wrangler login                        # OAuth login
wrangler whoami                       # Check auth/account
wrangler tail                         # Stream logs
wrangler tail --env production        # Tail specific environment
wrangler tail --status error          # Show only errors
```

## Resource Commands

### KV

```bash
wrangler kv namespace create NAME
wrangler kv key put "key" "value" --namespace-id=<id>
wrangler kv key get "key" --namespace-id=<id>
```

### D1

```bash
wrangler d1 create NAME
wrangler d1 execute NAME --command "SQL"
wrangler d1 migrations create NAME "description"
wrangler d1 migrations apply NAME
```

### R2

```bash
wrangler r2 bucket create NAME
wrangler r2 object put BUCKET/key --file path
wrangler r2 object get BUCKET/key
```

### Queues / Vectorize / Hyperdrive

```bash
wrangler queues create NAME
wrangler vectorize create NAME --dimensions N --metric cosine
wrangler hyperdrive create NAME --connection-string "..."
```

### Secrets

```bash
wrangler secret put NAME
wrangler secret list
wrangler secret delete NAME
```

## See Also

- [wrangler-patterns.md](./wrangler-patterns.md) - Common workflows and testing patterns
- [wrangler-gotchas.md](./wrangler-gotchas.md) - Limits, pitfalls, and troubleshooting
