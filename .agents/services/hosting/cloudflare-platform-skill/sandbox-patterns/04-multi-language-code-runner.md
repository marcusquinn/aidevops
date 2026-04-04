<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Multi-Language Code Runner

Handler-body-only example — uses the Worker boilerplate from `sandbox.md` Quick Start.

```typescript
const langs: Record<string, { cmd: string; ext: string }> = {
  python: { cmd: 'python3', ext: 'py' }, javascript: { cmd: 'node', ext: 'js' },
  typescript: { cmd: 'ts-node', ext: 'ts' }, bash: { cmd: 'bash', ext: 'sh' }
};
const { language, code } = await request.json();
const config = langs[language];
if (!config) return Response.json({ error: 'Unsupported language' }, { status: 400 });
const sandbox = getSandbox(env.Sandbox, 'code-runner');
const filename = `/workspace/script.${config.ext}`;
await sandbox.writeFile(filename, code);
const result = await sandbox.exec(`${config.cmd} ${filename}`);
return Response.json({ output: result.stdout, error: result.stderr, exitCode: result.exitCode });
```
