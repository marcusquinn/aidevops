<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# CI/CD Pipeline

Handler-body-only example — uses the Worker boilerplate from `sandbox.md` Quick Start.

```typescript
const { repo, branch } = await request.json();
const sandbox = getSandbox(env.Sandbox, `ci-${repo}-${Date.now()}`);
await sandbox.exec(`git clone -b ${branch} ${repo} /workspace/repo`);
const install = await sandbox.exec('npm install', {
  cwd: '/workspace/repo', stream: true, onOutput: (stream, data) => console.log(data)
});
if (!install.success) return Response.json({ success: false, error: 'Install failed' });
const test = await sandbox.exec('npm test', { cwd: '/workspace/repo' });
return Response.json({ success: test.success, output: test.stdout, exitCode: test.exitCode });
```
