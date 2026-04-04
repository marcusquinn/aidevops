<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Jupyter Integration

Handler-body-only examples — all use the Worker boilerplate from `sandbox.md` Quick Start.

**Dockerfile**: `FROM docker.io/cloudflare/sandbox:latest` + `RUN pip3 install --no-cache-dir jupyter-server ipykernel matplotlib pandas` + `EXPOSE 8888`

**Interactive notebook**:

```typescript
await sandbox.startProcess('jupyter notebook --ip=0.0.0.0 --port=8888 --no-browser', {
  processId: 'jupyter', cwd: '/workspace'
});
const exposed = await sandbox.exposePort(8888, { name: 'jupyter' });
return Response.json({ url: exposed.url });
```

**Headless execution** (nbconvert):

```typescript
const sandbox = getSandbox(env.Sandbox, 'data-analysis');
await sandbox.writeFile('/workspace/analysis.ipynb', JSON.stringify(notebook));
const result = await sandbox.exec(
  'jupyter nbconvert --to notebook --execute analysis.ipynb --output results.ipynb',
  { cwd: '/workspace' }
);
const output = await sandbox.readFile('/workspace/results.ipynb');
return Response.json({ success: result.success, notebook: JSON.parse(output.content) });
```
