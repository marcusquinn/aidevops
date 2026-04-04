<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Multi-Tenant

Handler-body-only example — uses the Worker boilerplate from `sandbox.md` Quick Start.

```typescript
const userId = request.headers.get('X-User-ID');
const sandbox = getSandbox(env.Sandbox, 'multi-tenant');
let session;
try { session = await sandbox.getSession(userId); }
catch { session = await sandbox.createSession({
  id: userId, cwd: `/workspace/users/${userId}`, env: { USER_ID: userId }
}); }
const code = await request.text();
const result = await session.exec(`python3 -c "${code}"`);
return Response.json({ output: result.stdout });
```
