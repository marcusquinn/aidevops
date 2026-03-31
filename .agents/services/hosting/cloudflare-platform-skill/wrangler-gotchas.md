# Wrangler Common Issues

Pitfalls, limits, and troubleshooting for the Wrangler CLI.

## Gotchas

### Binding IDs vs Names

- `binding` = code name; `id`/`database_id`/`bucket_name` = resource ID
- Preview bindings need separate IDs: `preview_id`, `preview_database_id`

### Environment Inheritance

- **Non-inheritable** (bindings, vars): must redeclare per environment
- **Inheritable** (routes, compatibility_date): can override

### Compatibility Dates

Always set — omitting causes unexpected runtime changes:

```jsonc
{ "compatibility_date": "2025-01-01" }
```

### Durable Objects Need script_name

With `getPlatformProxy`, always specify `script_name`:

```jsonc
{
  "durable_objects": {
    "bindings": [
      { "name": "MY_DO", "class_name": "MyDO", "script_name": "my-worker" }
    ]
  }
}
```

### Node.js Compatibility

Some bindings (e.g., Hyperdrive with `pg`) require:

```jsonc
{ "compatibility_flags": ["nodejs_compat_v2"] }
```

### Secrets in Local Dev

`wrangler secret put` only works deployed. Use `.dev.vars` locally. See [wrangler-patterns.md](./wrangler-patterns.md) for full secrets workflow.

### Local vs Remote Dev

`wrangler dev` = local simulation (fast, limited accuracy). `wrangler dev --remote` = remote execution (slower, production-accurate). See [wrangler-patterns.md](./wrangler-patterns.md) for dev patterns.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Auth failures | `wrangler logout && wrangler login && wrangler whoami` |
| Config errors | `wrangler check`; use `wrangler.jsonc` with `$schema` for validation |
| Binding not available | Verify binding in config; for envs, ensure defined for that env; local dev may need `--remote` |
| Deploy failures | `wrangler tail` (logs), `wrangler deploy --dry-run` (validate), `wrangler whoami` (account limits) |
| Stale local state | `rm -rf .wrangler/state`; try `wrangler dev --remote` or `--persist-to ./local-state` |

## Resources

- [Wrangler docs](https://developers.cloudflare.com/workers/wrangler/) | [Configuration](https://developers.cloudflare.com/workers/wrangler/configuration/) | [Commands](https://developers.cloudflare.com/workers/wrangler/commands/)
- [Templates](https://github.com/cloudflare/workers-sdk/tree/main/templates) | [Discord](https://discord.gg/cloudflaredev)

## See Also

- [wrangler.md](./wrangler.md) — Commands
- [wrangler-patterns.md](./wrangler-patterns.md) — Workflows
