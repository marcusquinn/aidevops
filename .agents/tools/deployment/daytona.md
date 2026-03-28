---
description: Daytona sandbox hosting — AI-native cloud development environments
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Daytona Hosting Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Cloud sandbox platform — ephemeral and stateful dev environments
- **SDK**: Python (`pip install daytona-sdk`) | TypeScript (`npm install @daytonaio/sdk`)
- **CLI**: `daytona` — install: `brew install daytonaio/tap/daytona` or `curl -sf -L https://download.daytona.io/daytona/install.sh | sudo bash`
- **API**: REST at `https://app.daytona.io/api` (Bearer token auth)
- **Helper**: `daytona-helper.sh [create|start|stop|destroy|list|exec|snapshot|status] [args]` — `destroy` maps to SDK `daytona.delete()` / REST `DELETE`
- **Auth**: `daytona login` (browser) or `export DAYTONA_API_KEY="..."` + `aidevops secret set DAYTONA_API_KEY`
- **Billing**: Per-second, resource-based (vCPU + RAM + disk). Stopped: disk only. Archived: minimal storage.
- **Isolation**: gVisor kernel-level sandbox per workspace

**Use cases**: AI agent code execution, CI/CD ephemeral runners, preview environments, LLM tool-use sandboxes

<!-- AI-CONTEXT-END -->

## Sandbox Lifecycle

```text
create ──► running ──► stopped ──► archived ──► deleted
               │            │           │
               │            ▼           ▼
               │         running     running
               ▼            ▲
            stopped ────────┘
```

```bash
daytona-helper.sh create my-sandbox --template python-3.11 --cpus 2 --memory 4
daytona-helper.sh start <sandbox-id>
daytona-helper.sh stop <sandbox-id>
daytona-helper.sh exec <sandbox-id> "python script.py"
daytona-helper.sh snapshot <sandbox-id> "after-deps-installed"
daytona-helper.sh destroy <sandbox-id>
daytona-helper.sh list
```

### Resource Limits

| Resource | Range | Default |
|----------|-------|---------|
| vCPU | 1-64 | 2 |
| RAM | 1-256 GB | 4 GB |
| Disk | 5-500 GB | 10 GB |
| GPU | Optional | None |

**GPU types**: A100 (80 GB), H100 (80 GB), L40S (48 GB).

```bash
daytona create --cpus 8 --memory 32 --disk 100 --gpu a100-80gb
daytona create --template python-3.11 --gpu h100-80gb --memory 64
daytona exec <sandbox-id> -- nvidia-smi
```

**Billing**: Running = vCPU + RAM + disk + GPU. Stopped = disk only. Archived = minimal storage. Deleted = free. Stop when idle; set auto-stop/auto-archive/auto-delete to prevent runaway costs.

```python
sandbox.set_autostop_interval(30)       # auto-stop after 30 min idle (0 to disable)
sandbox.set_auto_archive_interval(1440) # auto-archive 24h after stop
sandbox.set_auto_delete_interval(2880)  # auto-delete 48h after stop (negative to disable)
sandbox.refresh_activity()              # reset auto-stop countdown
```

## Workspace Templates and Images

### Custom Docker Images

```python
from daytona import Daytona, CreateSandboxFromImageParams, Resources, Image

daytona = Daytona()
# From image string
sandbox = daytona.create(CreateSandboxFromImageParams(
    image="python:3.12-slim", language="python",
    resources=Resources(cpu=2, memory=4, disk=20),
), timeout=150, on_snapshot_create_logs=print)

# Declarative builder (installs deps at snapshot time)
image = Image.base("alpine:3.18").pip_install(["numpy", "pandas"]).env({"MY_VAR": "value"})
sandbox = daytona.create(CreateSandboxFromImageParams(image=image, language="python",
    resources=Resources(cpu=4, memory=8)))
```

### CLI Templates

```bash
daytona template list
# Common: python-3.11 | node-20 | go-1.22 | rust-1.77 | ubuntu-22.04 | jupyter

daytona template create --from-sandbox <sandbox-id> --name "my-ml-env"
daytona create --template my-ml-env
```

## Networking

```bash
daytona port expose <sandbox-id> 8080   # returns public URL
url = sandbox.network.expose_port(8080) # Python SDK
```

## Security Isolation

Daytona uses **gVisor** (kernel-level) — syscalls intercepted per sandbox, no shared kernel, network isolated by default. Root inside sandbox does not grant host access.

**Isolation levels**: gVisor (default), Sysbox, LVMs, VMs (configurable per deployment).

**Threat model**: Safe for executing untrusted LLM-generated code. Not a substitute for application-level input validation.

## AI Agent Integration Patterns

```python
# Code execution sandbox (ephemeral — create, run, delete)
from daytona import Daytona
daytona = Daytona()

def run_code(code: str) -> dict:
    sb = daytona.create()
    try:
        r = sb.process.code_run(code)
        return {"result": r.result, "exit_code": r.exit_code}
    finally:
        daytona.delete(sb)

def run_shell(cmd: str) -> dict:
    sb = daytona.create()
    try:
        r = sb.process.exec(cmd, timeout=60)
        return {"result": r.result, "exit_code": r.exit_code}
    finally:
        daytona.delete(sb)
```

```bash
# CI/CD ephemeral runner
SANDBOX_ID=$(daytona-helper.sh create ci-runner-$CI_JOB_ID --template node-20)
daytona-helper.sh exec "$SANDBOX_ID" "npm ci && npm test"; EXIT_CODE=$?
daytona-helper.sh destroy "$SANDBOX_ID"; exit $EXIT_CODE

# Preview environment
SANDBOX_ID=$(daytona-helper.sh create "preview-pr-${PR_NUMBER}" --template node-20)
daytona-helper.sh exec "$SANDBOX_ID" "npm ci && npm run build && npm start &"
echo "Preview: $(daytona port expose "$SANDBOX_ID" 3000)"
```

## SDK Reference

### Python (Synchronous)

```python
from daytona import Daytona, CreateSandboxFromSnapshotParams, Resources

daytona = Daytona()  # reads DAYTONA_API_KEY from env
sandbox = daytona.create(CreateSandboxFromSnapshotParams(
    language="python", env_vars={"MY_VAR": "value"},
    labels={"project": "my-app"}, auto_stop_interval=30,
))

# Lifecycle
sandbox.stop(timeout=60); sandbox.start(timeout=60)
sandbox.resize(Resources(cpu=4, memory=8), timeout=60)
daytona.delete(sandbox, timeout=60)

# Execute
result = sandbox.process.code_run('print("hello")')  # result.result="hello", exit_code=0
result = sandbox.process.exec("ls -la", timeout=10)
result = sandbox.process.exec("echo $MY_VAR", cwd="/tmp", env={"MY_VAR": "Hello"})

# Filesystem
sandbox.filesystem.write("/tmp/script.py", "print('hello')")
content = sandbox.filesystem.read("/tmp/output.txt")

# Inspect
sandbox.refresh_data()
print(f"State: {sandbox.state}, CPU: {sandbox.cpu}, Memory: {sandbox.memory}GB")
all_sandboxes = daytona.list()
```

### Python (Async)

```python
from daytona import AsyncDaytona, CreateSandboxFromImageParams, Resources, Image

daytona = AsyncDaytona()
image = Image.base("alpine:3.18").pip_install(["numpy"])
sandbox = await daytona.create(CreateSandboxFromImageParams(
    image=image, language="python", resources=Resources(cpu=2, memory=4),
), timeout=120, on_snapshot_create_logs=lambda c: print(c, end=""))
result = await sandbox.process.code_run('import numpy; print(numpy.__version__)')
await daytona.delete(sandbox)
```

### TypeScript

```typescript
import { Daytona } from "@daytonaio/sdk";

const daytona = new Daytona();  // reads DAYTONA_API_KEY from env
const sandbox = await daytona.create({
  language: "typescript", envVars: { NODE_ENV: "test" }, autoStopInterval: 60,
});
const sandbox2 = await daytona.create({
  image: "node:20-slim", language: "javascript",
  resources: { cpu: 2, memory: 4, disk: 20 },
}, { timeout: 150, onSnapshotCreateLogs: console.log });

const result = await sandbox.process.codeRun('console.log("hello")');
const shellResult = await sandbox.process.exec("npm test", { timeout: 120 });
await sandbox.stop(); await sandbox.start(); await daytona.delete(sandbox);
```

## REST API

Base URL: `https://app.daytona.io/api` — `Authorization: Bearer $DAYTONA_API_KEY`

```bash
AUTH="Authorization: Bearer $DAYTONA_API_KEY"
curl -H "$AUTH" https://app.daytona.io/api/sandboxes                                          # list
curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"template":"python-3.11","cpu":2,"memory":4,"disk":10}' \
  https://app.daytona.io/api/sandboxes                                                        # create
curl -X POST -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>/start                      # start
curl -X POST -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>/stop                       # stop
curl -X DELETE -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>                          # delete
curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"command":"python script.py","timeout":60}' \
  https://app.daytona.io/api/sandboxes/<id>/exec                                              # exec
```

## Comparison

| Feature | Daytona | E2B | Modal | GitHub Codespaces |
|---------|---------|-----|-------|-------------------|
| Isolation | gVisor (kernel) | gVisor | Container | Container |
| Billing | Per-second | Per-second | Per-second | Per-hour |
| Snapshots | Yes | No | No | Yes |
| GPU | Yes | No | Yes | No |
| SDK | Python, TS | Python, TS, JS | Python | None |
| Persistent | Yes (stop/start) | No | No | Yes |
| AI-optimised | Yes | Yes | Partial | No |
| Image builder | Yes (declarative) | No | Yes | No |
| Auto-lifecycle | Yes (stop/archive/delete) | No | No | No |

**Choose Daytona**: stateful sandboxes with snapshots, GPU, stop/start lifecycle, or declarative image building.
**Choose E2B**: purely ephemeral sandboxes, simpler API, no persistence needed.
**Choose Modal**: serverless GPU functions, not interactive sandboxes.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Sandbox fails to start | `daytona-helper.sh status <id>` + `daytona logs <id>` — check resource limits, template name, API key |
| Command timeout | Increase `timeout=300` in `process.exec()` |
| Port not accessible | `daytona exec <id> -- ss -tlnp \| grep 8080` then `daytona port remove <id> 8080 && daytona port expose <id> 8080` |
| High costs | `daytona list --json \| jq -r '.[] \| select(.state=="running") \| .id' \| xargs -I{} daytona stop {}` |

## Related

- **Hosting comparison**: `tools/deployment/hosting-comparison.md`
- **Helper script**: `.agents/scripts/daytona-helper.sh`
- **Docs**: https://docs.daytona.io | **API**: https://docs.daytona.io/api | **Pricing**: https://www.daytona.io/pricing
- **Python SDK**: https://pypi.org/project/daytona-sdk/ | **TypeScript SDK**: https://www.npmjs.com/package/@daytonaio/sdk | **GitHub**: https://github.com/daytonaio/daytona
