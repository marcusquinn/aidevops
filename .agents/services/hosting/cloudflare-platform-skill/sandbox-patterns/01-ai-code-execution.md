<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI Code Execution

Handler-body-only example — uses the Worker boilerplate from `sandbox.md` Quick Start.

```typescript
const { code } = await request.json();
const sandbox = getSandbox(env.Sandbox, 'ai-agent');
await sandbox.writeFile('/workspace/user_code.py', code);
const result = await sandbox.exec('python3 /workspace/user_code.py');
return Response.json({ output: result.stdout, error: result.stderr, success: result.success });
```
