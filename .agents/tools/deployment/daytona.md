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
- **Helper**: `daytona-helper.sh [create|start|stop|destroy|list|exec|snapshot|status] [args]` — note: helper uses `destroy` (maps to SDK `daytona.delete()` / REST `DELETE`)
- **Auth**: `daytona login` (browser) or `export DAYTONA_API_KEY="..."` + `aidevops secret set DAYTONA_API_KEY`
- **Billing**: Per-second, resource-based (vCPU + RAM + disk). Stopped sandboxes: disk only. Archived: minimal storage cost.
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
# Create
daytona-helper.sh create my-sandbox --template python-3.11 --cpus 2 --memory 4

# Start / Stop (stopped = disk cost only)
daytona-helper.sh start <sandbox-id>
daytona-helper.sh stop <sandbox-id>

# Execute
daytona-helper.sh exec <sandbox-id> "python script.py"

# Snapshot (preserves full state cheaply)
daytona-helper.sh snapshot <sandbox-id> "after-deps-installed"

# Destroy (eliminates all costs)
daytona-helper.sh destroy <sandbox-id>

# List
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
# Custom resources
daytona create --cpus 8 --memory 32 --disk 100 --gpu a100-80gb

# GPU sandbox
daytona create --template python-3.11 --gpu h100-80gb --memory 64
daytona exec <sandbox-id> -- nvidia-smi
```

### Billing Model

| State | Billed for |
|-------|------------|
| Running | vCPU + RAM + disk + GPU |
| Stopped | Disk only |
| Archived | Minimal storage |
| Deleted | Nothing |

**Cost control**: Stop sandboxes when idle. Archive for long-term storage. Set auto-stop/auto-archive/auto-delete intervals to prevent runaway costs.

### Lifecycle Automation

```python
from daytona import Daytona

daytona = Daytona()
sandbox = daytona.create()

# Auto-stop after 30 min of inactivity (0 to disable)
sandbox.set_autostop_interval(30)

# Auto-archive 24h after stop
sandbox.set_auto_archive_interval(1440)

# Auto-delete 48h after stop (negative to disable)
sandbox.set_auto_delete_interval(2880)

# Refresh activity timer (resets auto-stop countdown)
sandbox.refresh_activity()
```

## Workspace Templates and Images

### Snapshots (Pre-Built Environments)

```python
from daytona import Daytona, CreateSandboxFromSnapshotParams

daytona = Daytona()

# Default Python sandbox
sandbox = daytona.create()

# From a named snapshot with custom settings
sandbox = daytona.create(CreateSandboxFromSnapshotParams(
    language="python",
    snapshot="my-snapshot-id",
    env_vars={"DEBUG": "true"},
    labels={"project": "my-app"},
    auto_stop_interval=60,
))
```

### Custom Docker Images

```python
from daytona import Daytona, CreateSandboxFromImageParams, Resources, Image

daytona = Daytona()

# From a Docker image string
sandbox = daytona.create(CreateSandboxFromImageParams(
    image="python:3.12-slim",
    language="python",
    resources=Resources(cpu=2, memory=4, disk=20),
), timeout=150, on_snapshot_create_logs=print)

# Declarative Image builder (installs deps at snapshot time)
image = (
    Image.base("alpine:3.18")
    .pip_install(["numpy", "pandas"])
    .env({"MY_VAR": "value"})
)
sandbox = daytona.create(CreateSandboxFromImageParams(
    image=image,
    language="python",
    resources=Resources(cpu=4, memory=8),
))
```

### CLI Templates

```bash
daytona template list

# Common: python-3.11 | node-20 | go-1.22 | rust-1.77 | ubuntu-22.04 | jupyter

# Custom template from existing sandbox
daytona template create --from-sandbox <sandbox-id> --name "my-ml-env"
daytona create --template my-ml-env
```

## Networking

```bash
# Expose port publicly (returns public URL)
daytona port expose <sandbox-id> 8080

# Python SDK
url = sandbox.network.expose_port(8080)
```

## Security Isolation

Daytona uses **gVisor** (kernel-level) — syscalls intercepted per sandbox, no shared kernel between sandboxes, network isolated by default. Root inside sandbox does not grant host access.

**Isolation levels**: gVisor (default), Sysbox, LVMs, VMs (configurable per deployment).

**Threat model**: Safe for executing untrusted LLM-generated code. Not a substitute for application-level input validation.

## AI Agent Integration Patterns

### Code Execution Sandbox

```python
from daytona import Daytona

daytona = Daytona()

def execute_agent_code(code: str) -> dict:
    sandbox = daytona.create()
    try:
        # Use code_run for direct code execution
        result = sandbox.process.code_run(code)
        return {"result": result.result, "exit_code": result.exit_code}
    finally:
        daytona.delete(sandbox)

# Or use exec for shell commands
def execute_shell(command: str) -> dict:
    sandbox = daytona.create()
    try:
        result = sandbox.process.exec(command, timeout=60)
        return {"result": result.result, "exit_code": result.exit_code}
    finally:
        daytona.delete(sandbox)
```

### CI/CD Ephemeral Runner

```bash
SANDBOX_ID=$(daytona-helper.sh create ci-runner-$CI_JOB_ID --template node-20)
daytona-helper.sh exec "$SANDBOX_ID" "npm ci && npm test"
EXIT_CODE=$?
daytona-helper.sh destroy "$SANDBOX_ID"
exit $EXIT_CODE
```

### Preview Environment

```bash
SANDBOX_ID=$(daytona-helper.sh create "preview-pr-${PR_NUMBER}" --template node-20)
daytona-helper.sh exec "$SANDBOX_ID" "npm ci && npm run build && npm start &"
PUBLIC_URL=$(daytona port expose "$SANDBOX_ID" 3000)
echo "Preview: $PUBLIC_URL"
```

## SDK Reference

### Python (Synchronous)

```python
from daytona import Daytona, CreateSandboxFromSnapshotParams, Resources

daytona = Daytona()  # reads DAYTONA_API_KEY from env

# Create
sandbox = daytona.create()
sandbox = daytona.create(CreateSandboxFromSnapshotParams(
    language="python",
    env_vars={"MY_VAR": "value"},
    labels={"project": "my-app"},
    auto_stop_interval=30,
))

# Lifecycle
sandbox.stop(timeout=60)
sandbox.start(timeout=60)
sandbox.resize(Resources(cpu=4, memory=8), timeout=60)
daytona.delete(sandbox, timeout=60)

# Execute code directly (uses sandbox language runtime)
result = sandbox.process.code_run('print("hello")')
print(result.result)       # "hello"
print(result.exit_code)    # 0

# Execute shell commands
result = sandbox.process.exec("ls -la", timeout=10)
result = sandbox.process.exec("echo $MY_VAR", cwd="/tmp", env={"MY_VAR": "Hello"})

# Filesystem
sandbox.filesystem.write("/tmp/script.py", "print('hello')")
content = sandbox.filesystem.read("/tmp/output.txt")

# State inspection
sandbox.refresh_data()
print(f"State: {sandbox.state}, CPU: {sandbox.cpu}, Memory: {sandbox.memory}GB")

# List and filter
all_sandboxes = daytona.list()
```

### Python (Async)

```python
from daytona import AsyncDaytona, CreateSandboxFromImageParams, Resources, Image

daytona = AsyncDaytona()

image = Image.base("alpine:3.18").pip_install(["numpy"])
sandbox = await daytona.create(CreateSandboxFromImageParams(
    image=image,
    language="python",
    resources=Resources(cpu=2, memory=4),
), timeout=120, on_snapshot_create_logs=lambda chunk: print(chunk, end=""))

result = await sandbox.process.code_run('import numpy; print(numpy.__version__)')
await daytona.delete(sandbox)
```

### TypeScript

```typescript
import { Daytona } from "@daytonaio/sdk";

const daytona = new Daytona();  // reads DAYTONA_API_KEY from env

// Create from snapshot
const sandbox = await daytona.create({
  language: "typescript",
  envVars: { NODE_ENV: "test" },
  autoStopInterval: 60,
});

// Create from image with resources
const sandbox2 = await daytona.create({
  image: "node:20-slim",
  language: "javascript",
  resources: { cpu: 2, memory: 4, disk: 20 },
}, { timeout: 150, onSnapshotCreateLogs: console.log });

// Execute
const result = await sandbox.process.codeRun('console.log("hello")');
const shellResult = await sandbox.process.exec("npm test", { timeout: 120 });

// Lifecycle
await sandbox.stop();
await sandbox.start();
await daytona.delete(sandbox);
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

```bash
# Sandbox fails to start
daytona-helper.sh status <sandbox-id>
daytona logs <sandbox-id>
# Causes: resource limits exceeded, template not found, API key expired

# Command timeout — increase the timeout value
result = sandbox.process.exec("long-running-command", timeout=300)

# Port not accessible — verify listening, then re-expose
daytona exec <sandbox-id> -- ss -tlnp | grep 8080
daytona port remove <sandbox-id> 8080 && daytona port expose <sandbox-id> 8080

# High costs — stop running sandboxes
daytona list --json | jq -r '.[] | select(.state=="running") | .id' | xargs -I{} daytona stop {}
```

## Related

- **Hosting comparison**: `tools/deployment/hosting-comparison.md` — Daytona vs Fly.io vs Coolify vs Cloudron vs Vercel decision guide
- **Helper script**: `.agents/scripts/daytona-helper.sh`

## References

- **Docs**: https://docs.daytona.io
- **API**: https://docs.daytona.io/api
- **Python SDK**: https://pypi.org/project/daytona-sdk/
- **TypeScript SDK**: https://www.npmjs.com/package/@daytonaio/sdk
- **GitHub**: https://github.com/daytonaio/daytona
- **Pricing**: https://www.daytona.io/pricing
