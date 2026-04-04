<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Interactive Dev Environment

Handler-body-only example — uses the Worker boilerplate from `sandbox.md` Quick Start.

```typescript
// Requires proxyToSandbox() call first (see sandbox.md)
const sandbox = getSandbox(env.Sandbox, 'ide', { normalizeId: true });
await sandbox.exec('curl -fsSL https://code-server.dev/install.sh | sh');
await sandbox.startProcess('code-server --bind-addr 0.0.0.0:8080', { processId: 'vscode' });
const exposed = await sandbox.exposePort(8080);
return Response.json({ url: exposed.url });
```
