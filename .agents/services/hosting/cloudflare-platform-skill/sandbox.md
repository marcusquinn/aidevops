<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Sandbox SDK

Run isolated containers on Cloudflare's edge. Each sandbox pairs a Durable Object with a container, reuses state when IDs match. Use cases: AI code execution, dev environments, CI/CD, data analysis, multi-tenant runners.

## Quick Start

```typescript
import { getSandbox, proxyToSandbox, type Sandbox } from '@cloudflare/sandbox';
export { Sandbox } from '@cloudflare/sandbox';

type Env = { Sandbox: DurableObjectNamespace<Sandbox>; };

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // CRITICAL: proxyToSandbox MUST be called first for preview URLs
    const proxyResponse = await proxyToSandbox(request, env);
    if (proxyResponse) return proxyResponse;

    const sandbox = getSandbox(env.Sandbox, 'my-sandbox');
    const result = await sandbox.exec('python3 -c "print(2 + 2)"');
    return Response.json({ output: result.stdout });
  }
};
```

## Configuration

**`wrangler.jsonc`**

```jsonc
{
  "name": "my-sandbox-worker",
  "main": "src/index.ts",
  "compatibility_date": "2024-01-01",
  "containers": [{
    "class_name": "Sandbox",
    "image": "./Dockerfile",
    "instance_type": "lite",  // lite | standard | heavy
    "max_instances": 5
  }],
  "durable_objects": {
    "bindings": [{ "class_name": "Sandbox", "name": "Sandbox" }]
  },
  "migrations": [{
    "tag": "v1",
    "new_sqlite_classes": ["Sandbox"]
  }]
}
```

**`Dockerfile`**

```dockerfile
FROM docker.io/cloudflare/sandbox:latest
RUN pip3 install --no-cache-dir pandas numpy matplotlib
EXPOSE 8080 3000  # Required for wrangler dev
```

## Core APIs

- `getSandbox(namespace, id, options?)` → Get/create sandbox
- `sandbox.exec(command, options?)` → Execute command
- `sandbox.readFile(path)` / `writeFile(path, content)` → File ops
- `sandbox.startProcess(command, options)` → Background process
- `sandbox.exposePort(port, options)` → Get preview URL
- `sandbox.createSession(options)` → Isolated session

## Key Rules

- Call `proxyToSandbox()` first so preview URLs resolve correctly
- Reuse the sandbox ID when you want persistent state
- Store persistent files in `/workspace`
- Use `normalizeId: true` for preview URLs
- Retry `CONTAINER_NOT_READY` during provisioning or wake-up

## Resources

[Patterns](./sandbox-patterns.md) · [Gotchas](./sandbox-gotchas.md) · [Official Docs](https://developers.cloudflare.com/sandbox/)
