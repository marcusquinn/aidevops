# Gotchas & Best Practices

## Common Issues

**Container Not Ready** — `CONTAINER_NOT_READY` on first request or after sleep. Retry after 2-3s:

```typescript
async function execWithRetry(sandbox, cmd) {
  for (let i = 0; i < 3; i++) {
    try {
      return await sandbox.exec(cmd);
    } catch (e) {
      if (e.code === 'CONTAINER_NOT_READY') {
        await new Promise(r => setTimeout(r, 2000));
        continue;
      }
      throw e;
    }
  }
}
```

**Port Exposure Fails in Dev** — "Connection refused: container port not found" means missing `EXPOSE` in Dockerfile. Add `EXPOSE <port>` (only needed for `wrangler dev`; production auto-exposes).

**Preview URLs Not Working** — check in order:
1. Custom domain configured? (not `.workers.dev`)
2. Wildcard DNS set up? (`*.domain.com → worker.domain.com`)
3. `normalizeId: true` in getSandbox?
4. `proxyToSandbox()` called first in fetch?

**Slow First Request** — cold start from container provisioning. Mitigations: `sleepAfter` instead of new sandboxes, pre-warm with cron triggers, `keepAlive: true` for critical sandboxes.

**File Not Persisting** — `/tmp` and ephemeral paths don't survive. Use `/workspace` for persistent files.

## Performance

**Sandbox ID Strategy** — reuse IDs per user/task; never use `Date.now()` as ID:

```typescript
// ❌ BAD: Creates new sandbox every time (slow, expensive)
const sandbox = getSandbox(env.Sandbox, `user-${Date.now()}`);

// ✅ GOOD: Reuse sandbox per user
const sandbox = getSandbox(env.Sandbox, `user-${userId}`);

// ✅ GOOD: Reuse for temporary tasks
const sandbox = getSandbox(env.Sandbox, 'shared-runner');
```

**Sleep Configuration:**

```typescript
// Cost-optimized: Sleep after 30min inactivity
const sandbox = getSandbox(env.Sandbox, 'id', {
  sleepAfter: '30m',
  keepAlive: false
});

// Always-on (higher cost, faster response)
const sandbox = getSandbox(env.Sandbox, 'id', {
  keepAlive: true
});
```

**High Traffic** — increase `max_instances` in wrangler config:

```jsonc
{
  "containers": [{
    "class_name": "Sandbox",
    "max_instances": 50  // Allow 50 concurrent sandboxes
  }]
}
```

## Security

**Isolation** — each sandbox is an isolated container (filesystem, network, processes). Use unique IDs per tenant; sandboxes cannot communicate directly.

**Input Validation** — never interpolate user code into exec strings:

```typescript
// ❌ DANGEROUS: Command injection
const result = await sandbox.exec(`python3 -c "${userCode}"`);

// ✅ SAFE: Write to file, execute file
await sandbox.writeFile('/workspace/user_code.py', userCode);
const result = await sandbox.exec('python3 /workspace/user_code.py');
```

**Resource Limits** — always set timeouts on exec:

```typescript
const result = await sandbox.exec('python3 script.py', {
  timeout: 30000  // 30 seconds
});
```

**Secrets** — never hardcode; pass via env:

```typescript
// ❌ NEVER hardcode secrets
const token = 'ghp_abc123';

// ✅ Use environment secrets
const token = env.GITHUB_TOKEN;

// Pass to sandbox via exec env
const result = await sandbox.exec('git clone ...', {
  env: { GIT_TOKEN: token }
});
```

**Preview URL Tokens** — auto-generated tokens rotate on each expose operation, reducing unauthorized access risk. Tokens can be leaked prior to rotation.

## Limits

| | |
|---|---|
| Instance types | lite (256MB), standard (512MB), heavy (1GB) |
| Default exec timeout | 120s |
| First deploy | 2-3 min (container provisioning) |
| Cold start | 2-3s (waking from sleep) |

## Resources

- [Official Docs](https://developers.cloudflare.com/sandbox/)
- [Production Guide](https://developers.cloudflare.com/sandbox/guides/production-deployment/)
- [API Reference](https://developers.cloudflare.com/sandbox/api/)
- [Examples](https://github.com/cloudflare/sandbox-sdk/tree/main/examples)
- [npm Package](https://www.npmjs.com/package/@cloudflare/sandbox)
- [Discord Support](https://discord.cloudflare.com)
