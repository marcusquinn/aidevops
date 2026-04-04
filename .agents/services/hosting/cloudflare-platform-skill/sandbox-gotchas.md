<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gotchas & Best Practices

## Common Issues

### Container Not Ready
`CONTAINER_NOT_READY` — container provisioning (first request or after sleep). Retry after 2-3s:

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

### Port Exposure Fails in Dev
Missing `EXPOSE <port>` in Dockerfile (only needed for `wrangler dev`; production auto-exposes).

### Preview URLs Not Working
- Custom domain configured? (not `.workers.dev`)
- Wildcard DNS set up? (`*.domain.com → worker.domain.com`)
- `normalizeId: true` in getSandbox?
- `proxyToSandbox()` called first in fetch?

### Slow First Request
Cold start from provisioning. Use `sleepAfter` instead of new sandboxes, pre-warm with cron triggers, or `keepAlive: true` for critical sandboxes.

### File Not Persisting
Use `/workspace` for persistent files; `/tmp` and ephemeral paths don't survive.

## Performance

### Sandbox ID Strategy
```typescript
// ❌ New sandbox every time (slow, expensive)
const sandbox = getSandbox(env.Sandbox, `user-${Date.now()}`);

// ✅ Reuse per user
const sandbox = getSandbox(env.Sandbox, `user-${userId}`);

// ✅ Reuse for temporary tasks
const sandbox = getSandbox(env.Sandbox, 'shared-runner');
```

### Sleep Configuration
```typescript
// Cost-optimized: sleep after 30min inactivity
const sandbox = getSandbox(env.Sandbox, 'id', {
  sleepAfter: '30m',
  keepAlive: false
});

// Always-on (higher cost, faster response)
const sandbox = getSandbox(env.Sandbox, 'id', {
  keepAlive: true
});
```

### Max Instances for High Traffic
```jsonc
{
  "containers": [{
    "class_name": "Sandbox",
    "max_instances": 50  // Allow 50 concurrent sandboxes
  }]
}
```

## Security

### Sandbox Isolation
Each sandbox = isolated container (filesystem, network, processes). Use unique IDs per tenant. Sandboxes cannot communicate directly.

### Input Validation
```typescript
// ❌ Command injection
const result = await sandbox.exec(`python3 -c "${userCode}"`);

// ✅ Write to file, execute file
await sandbox.writeFile('/workspace/user_code.py', userCode);
const result = await sandbox.exec('python3 /workspace/user_code.py');
```

### Resource Limits
```typescript
// Timeout long-running commands
const result = await sandbox.exec('python3 script.py', {
  timeout: 30000  // 30 seconds
});
```

### Secrets Management
```typescript
// ❌ Never hardcode secrets
const token = 'ghp_abc123';

// ✅ Use environment secrets
const token = env.GITHUB_TOKEN;

// Pass to sandbox via exec env
const result = await sandbox.exec('git clone ...', {
  env: { GIT_TOKEN: token }
});
```

### Preview URL Security
Preview URLs include auto-generated tokens (e.g., `https://8080-sandbox-abc123def456.yourdomain.com`) that rotate on each expose operation. Note: tokens can be leaked prior to rotation.

## Limits & Resources

**Instance types**: lite (256MB), standard (512MB), heavy (1GB)  
**Default timeout**: 120s for exec operations  
**First deploy**: 2-3 min for container provisioning  
**Cold start**: 2-3s when waking from sleep

**Docs**: [Official](https://developers.cloudflare.com/sandbox/) | [API](https://developers.cloudflare.com/sandbox/api/) | [Examples](https://github.com/cloudflare/sandbox-sdk/tree/main/examples) | [npm](https://www.npmjs.com/package/@cloudflare/sandbox) | [Production Guide](https://developers.cloudflare.com/sandbox/guides/production-deployment/) | [Discord](https://discord.cloudflare.com)
