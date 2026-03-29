# Common Patterns

All patterns use the Worker boilerplate from `sandbox.md` Quick Start. First example shows the full Worker; subsequent examples show only the handler body.

## AI Code Execution Agent

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { code } = await request.json();
    const sandbox = getSandbox(env.Sandbox, 'ai-agent');
    await sandbox.writeFile('/workspace/user_code.py', code);
    const result = await sandbox.exec('python3 /workspace/user_code.py');
    return Response.json({
      output: result.stdout, error: result.stderr, success: result.success
    });
  }
};
```

## Interactive Dev Environment

```typescript
// Requires proxyToSandbox() call first (see sandbox.md)
const sandbox = getSandbox(env.Sandbox, 'ide', { normalizeId: true });
await sandbox.exec('curl -fsSL https://code-server.dev/install.sh | sh');
await sandbox.startProcess('code-server --bind-addr 0.0.0.0:8080', { processId: 'vscode' });
const exposed = await sandbox.exposePort(8080);
return Response.json({ url: exposed.url });
```

## CI/CD Pipeline

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

## Multi-Language Code Runner

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

## Multi-Tenant Pattern

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

## Jupyter Integration

**Dockerfile**: `FROM docker.io/cloudflare/sandbox:latest` + `RUN pip3 install --no-cache-dir jupyter-server ipykernel matplotlib pandas` + `EXPOSE 8888`

**Worker** (interactive notebook):

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

## Git Operations

```typescript
await sandbox.exec('git clone https://github.com/user/repo.git /workspace/repo');
await sandbox.exec('git clone -b main --single-branch https://github.com/user/repo.git /workspace/repo');
const token = env.GITHUB_TOKEN; // Authenticated clone
await sandbox.exec(`git clone https://${token}@github.com/user/private-repo.git`);
await sandbox.exec('git pull', { cwd: '/workspace/repo' });
await sandbox.exec('git checkout -b feature', { cwd: '/workspace/repo' });
```
