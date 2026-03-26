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

- **Type**: Cloud sandbox platform — ephemeral, stateful dev environments
- **SDK**: Python (`pip install daytona-sdk`) | TypeScript (`npm install @daytonaio/sdk`)
- **CLI**: `daytona` (install: `brew install daytonaio/tap/daytona` or `curl -sf -L https://download.daytona.io/daytona/install.sh | sudo bash`)
- **API**: REST at `https://app.daytona.io/api` (Bearer token auth)
- **Helper**: `daytona-helper.sh [create|start|stop|destroy|list|exec|snapshot|status] [args]`
- **Billing**: Per-second, resource-based (vCPU + RAM + disk)
- **Isolation**: gVisor kernel-level sandbox per workspace

**Use cases**: AI agent code execution, CI/CD ephemeral runners, preview environments, interactive dev containers, LLM tool-use sandboxes

<!-- AI-CONTEXT-END -->

Daytona provides cloud-hosted, ephemeral development environments (sandboxes) optimised for AI agent workflows. Each sandbox is a fully isolated Linux environment with per-second billing, stateful snapshots, and a REST/SDK API for programmatic lifecycle management.

## Provider Overview

### Daytona Characteristics

- **Deployment Type**: Managed cloud sandbox (SaaS)
- **Isolation**: gVisor (kernel-level) — stronger than Docker namespaces
- **Billing**: Per-second, per-resource (vCPU, RAM, disk) — no idle charges when stopped
- **Persistence**: Stateful snapshots — stop and resume without losing state
- **GPU**: Optional GPU attachment (A100, H100, L40S) for ML workloads
- **Networking**: Private by default; optional public port exposure
- **Templates**: Pre-built workspace templates (Python, Node, Go, Rust, etc.)
- **API-first**: Full REST API + Python/TypeScript SDKs

### Best Use Cases

- **AI agent code execution** — safe, isolated environment for LLM-generated code
- **CI/CD ephemeral runners** — spin up, run tests, destroy; pay only for runtime
- **Preview environments** — per-PR sandboxes with public URL exposure
- **Interactive dev containers** — persistent workspaces for remote development
- **LLM tool-use sandboxes** — give agents a safe shell without host system risk
- **Batch processing** — parallel sandboxes for data pipelines or test suites

### Pricing Model

| Resource | Rate |
|----------|------|
| vCPU | Per-second, per-core |
| RAM | Per-second, per GB |
| Disk | Per-second, per GB |
| GPU (A100 80GB) | Per-second |
| GPU (H100 80GB) | Per-second |
| Stopped sandbox | Disk cost only (vCPU/RAM = $0) |

**Cost optimisation**: Stop sandboxes when idle — only disk is billed. Destroy when done to eliminate all costs. Use snapshots to preserve state cheaply.

## Prerequisites

### Install Daytona CLI

```bash
# macOS (Homebrew)
brew install daytonaio/tap/daytona

# Linux / macOS (curl)
curl -sf -L https://download.daytona.io/daytona/install.sh | sudo bash

# Verify
daytona version
```

### Install SDK

```bash
# Python
pip install daytona-sdk

# TypeScript / Node.js
npm install @daytonaio/sdk
```

### Authentication

```bash
# CLI login (opens browser)
daytona login

# API key (for programmatic use)
# Generate at: https://app.daytona.io/settings/api-keys
export DAYTONA_API_KEY="your-api-key"

# Verify
daytona whoami
```

Store the API key securely:

```bash
aidevops secret set DAYTONA_API_KEY
```

## Sandbox Lifecycle

### Create a Sandbox

```bash
# CLI — default template
daytona create

# CLI — specific template
daytona create --template python-3.11

# CLI — custom resources
daytona create --cpus 4 --memory 8 --disk 20

# Helper script
daytona-helper.sh create my-sandbox --template python-3.11 --cpus 2 --memory 4

# Python SDK
from daytona_sdk import Daytona, CreateSandboxParams

daytona = Daytona(api_key=os.environ["DAYTONA_API_KEY"])
sandbox = daytona.create(CreateSandboxParams(
    language="python",
    template="python-3.11",
    resources={"cpus": 2, "memory": 4, "disk": 10},
))
print(sandbox.id)
```

### Start / Stop

```bash
# CLI
daytona start <sandbox-id>
daytona stop <sandbox-id>

# Helper
daytona-helper.sh start <sandbox-id>
daytona-helper.sh stop <sandbox-id>

# Python SDK
daytona.start(sandbox_id)
daytona.stop(sandbox_id)
```

### Execute Commands

```bash
# CLI — run command in sandbox
daytona exec <sandbox-id> -- bash -c "python script.py"

# Helper
daytona-helper.sh exec <sandbox-id> "python script.py"

# Python SDK — synchronous
result = sandbox.process.exec("python script.py", timeout=30)
print(result.stdout)
print(result.exit_code)

# Python SDK — streaming output
for chunk in sandbox.process.exec_stream("npm test"):
    print(chunk, end="", flush=True)
```

### Destroy

```bash
# CLI
daytona destroy <sandbox-id>

# Helper
daytona-helper.sh destroy <sandbox-id>

# Python SDK
daytona.destroy(sandbox_id)
```

### List Sandboxes

```bash
# CLI
daytona list

# Helper
daytona-helper.sh list

# Python SDK
sandboxes = daytona.list()
for s in sandboxes:
    print(f"{s.id}  {s.state}  {s.template}")
```

## Stateful Snapshots

Snapshots preserve the full sandbox state (filesystem, processes, memory) so you can stop and resume without losing work.

```bash
# Create snapshot
daytona snapshot create <sandbox-id> --name "after-deps-installed"

# List snapshots
daytona snapshot list <sandbox-id>

# Restore from snapshot
daytona snapshot restore <sandbox-id> <snapshot-id>

# Helper
daytona-helper.sh snapshot <sandbox-id> "after-deps-installed"
```

**Cost note**: Snapshots are stored as disk — billed at disk rate only. No vCPU/RAM cost while stopped.

## Workspace Templates

Templates are pre-configured sandbox images with language runtimes, tools, and dependencies pre-installed.

```bash
# List available templates
daytona template list

# Common templates
daytona create --template python-3.11        # Python 3.11 + pip
daytona create --template node-20            # Node.js 20 + npm
daytona create --template go-1.22            # Go 1.22
daytona create --template rust-1.77          # Rust + cargo
daytona create --template ubuntu-22.04       # Bare Ubuntu
daytona create --template jupyter            # Jupyter Lab + Python
```

### Custom Templates

```bash
# Create template from existing sandbox
daytona template create --from-sandbox <sandbox-id> --name "my-ml-env"

# Use custom template
daytona create --template my-ml-env
```

## Resource Limits

| Resource | Default | Maximum |
|----------|---------|---------|
| vCPU | 2 | 64 |
| RAM | 4 GB | 256 GB |
| Disk | 10 GB | 500 GB |
| GPU | None | 8x H100 |
| Sandboxes per account | 10 | Contact sales |

```bash
# Create with specific resources
daytona create \
  --cpus 8 \
  --memory 32 \
  --disk 100 \
  --gpu a100-80gb

# Python SDK
sandbox = daytona.create(CreateSandboxParams(
    resources={
        "cpus": 8,
        "memory": 32,
        "disk": 100,
        "gpu": "a100-80gb",
    }
))
```

## GPU Sandboxes

```bash
# Available GPU types
# a100-80gb   — NVIDIA A100 80GB (ML training, inference)
# h100-80gb   — NVIDIA H100 80GB (large model training)
# l40s-48gb   — NVIDIA L40S 48GB (inference, rendering)

# Create GPU sandbox
daytona create --template python-3.11 --gpu h100-80gb --memory 64

# Verify GPU in sandbox
daytona exec <sandbox-id> -- nvidia-smi
```

## Networking and Port Exposure

```bash
# Expose a port publicly (returns public URL)
daytona port expose <sandbox-id> 8080

# List exposed ports
daytona port list <sandbox-id>

# Remove port exposure
daytona port remove <sandbox-id> 8080

# Python SDK
url = sandbox.network.expose_port(8080)
print(f"Public URL: {url}")
```

## Security Isolation Model

Daytona uses **gVisor** (Google's kernel-level sandbox) for isolation:

- Each sandbox runs in its own gVisor instance — syscalls are intercepted and validated
- No shared kernel between sandboxes (unlike standard Docker containers)
- Network is isolated by default — sandboxes cannot reach each other or the host
- Filesystem is ephemeral unless snapshotted
- Root access inside sandbox does not grant host access

**Threat model**: Safe for executing untrusted LLM-generated code. The gVisor boundary prevents container escapes that affect standard Docker. Not a substitute for application-level input validation.

## AI Agent Integration Patterns

### Pattern 1: Code Execution Sandbox

Give an LLM agent a safe shell for code execution:

```python
from daytona_sdk import Daytona, CreateSandboxParams
import os

daytona = Daytona(api_key=os.environ["DAYTONA_API_KEY"])

def execute_agent_code(code: str, language: str = "python") -> dict:
    """Execute LLM-generated code in an isolated sandbox."""
    sandbox = daytona.create(CreateSandboxParams(
        language=language,
        template=f"{language}-3.11" if language == "python" else f"{language}-20",
        resources={"cpus": 2, "memory": 4, "disk": 10},
    ))
    try:
        # Write code to file
        sandbox.process.exec(f"cat > /tmp/agent_code.py << 'EOF'\n{code}\nEOF")
        # Execute
        result = sandbox.process.exec("python /tmp/agent_code.py", timeout=60)
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.exit_code,
        }
    finally:
        daytona.destroy(sandbox.id)
```

### Pattern 2: Persistent Dev Environment

Long-running workspace that survives across sessions:

```bash
# Create once
SANDBOX_ID=$(daytona-helper.sh create dev-env --template python-3.11)

# Stop when not in use (saves vCPU/RAM cost)
daytona-helper.sh stop "$SANDBOX_ID"

# Resume later
daytona-helper.sh start "$SANDBOX_ID"
daytona-helper.sh exec "$SANDBOX_ID" "python my_script.py"
```

### Pattern 3: CI/CD Ephemeral Runner

```bash
# In CI pipeline
SANDBOX_ID=$(daytona-helper.sh create ci-runner-$CI_JOB_ID --template node-20)
daytona-helper.sh exec "$SANDBOX_ID" "npm ci && npm test"
EXIT_CODE=$?
daytona-helper.sh destroy "$SANDBOX_ID"
exit $EXIT_CODE
```

### Pattern 4: Preview Environments

```bash
# Per-PR preview environment
SANDBOX_ID=$(daytona-helper.sh create "preview-pr-${PR_NUMBER}" --template node-20)
daytona-helper.sh exec "$SANDBOX_ID" "npm ci && npm run build && npm start &"
PUBLIC_URL=$(daytona port expose "$SANDBOX_ID" 3000)
echo "Preview: $PUBLIC_URL"
```

## Python SDK Reference

```python
from daytona_sdk import Daytona, CreateSandboxParams, SandboxState

# Initialise
daytona = Daytona(api_key=os.environ["DAYTONA_API_KEY"])

# Create
sandbox = daytona.create(CreateSandboxParams(
    language="python",
    template="python-3.11",
    resources={"cpus": 2, "memory": 4, "disk": 10},
    env_vars={"MY_VAR": "value"},
    labels={"project": "my-app", "env": "ci"},
))

# Lifecycle
daytona.start(sandbox.id)
daytona.stop(sandbox.id)
daytona.destroy(sandbox.id)

# Execute
result = sandbox.process.exec("ls -la", timeout=10)
print(result.stdout, result.exit_code)

# File operations
sandbox.filesystem.write("/tmp/script.py", "print('hello')")
content = sandbox.filesystem.read("/tmp/output.txt")

# List
sandboxes = daytona.list()
running = [s for s in sandboxes if s.state == SandboxState.RUNNING]

# Get by ID
sandbox = daytona.get(sandbox_id)
print(sandbox.state, sandbox.resources)
```

## TypeScript SDK Reference

```typescript
import { Daytona, CreateSandboxParams } from "@daytonaio/sdk";

const daytona = new Daytona({ apiKey: process.env.DAYTONA_API_KEY });

// Create
const sandbox = await daytona.create({
  language: "typescript",
  template: "node-20",
  resources: { cpus: 2, memory: 4, disk: 10 },
  envVars: { NODE_ENV: "test" },
});

// Execute
const result = await sandbox.process.exec("npm test", { timeout: 120 });
console.log(result.stdout, result.exitCode);

// Destroy
await daytona.destroy(sandbox.id);
```

## REST API Reference

Base URL: `https://app.daytona.io/api`

```bash
# Auth header
AUTH="Authorization: Bearer $DAYTONA_API_KEY"

# List sandboxes
curl -H "$AUTH" https://app.daytona.io/api/sandboxes

# Create sandbox
curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"template":"python-3.11","resources":{"cpus":2,"memory":4,"disk":10}}' \
  https://app.daytona.io/api/sandboxes

# Start
curl -X POST -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>/start

# Stop
curl -X POST -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>/stop

# Destroy
curl -X DELETE -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>

# Execute command
curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"command":"python script.py","timeout":60}' \
  https://app.daytona.io/api/sandboxes/<id>/exec
```

## Comparison with Alternatives

| Feature | Daytona | E2B | Modal | GitHub Codespaces |
|---------|---------|-----|-------|-------------------|
| Isolation | gVisor (kernel) | gVisor | Container | Container |
| Billing | Per-second | Per-second | Per-second | Per-hour |
| Snapshots | Yes | No | No | Yes |
| GPU | Yes | No | Yes | No |
| SDK | Python, TS | Python, TS, JS | Python | None |
| Templates | Yes | Yes | No | Yes |
| Persistent | Yes (stop/start) | No (ephemeral) | No | Yes |
| Self-host | No | No | No | No |
| AI-optimised | Yes | Yes | Partial | No |

**Choose Daytona when**: You need stateful sandboxes with snapshots, GPU support, or per-second billing with stop/start lifecycle.

**Choose E2B when**: You need purely ephemeral sandboxes with a simpler API and no persistence requirement.

**Choose Modal when**: You need serverless functions with GPU, not interactive sandboxes.

## Troubleshooting

### Sandbox fails to start

```bash
# Check status
daytona-helper.sh status <sandbox-id>

# View logs
daytona logs <sandbox-id>

# Common causes:
# - Resource limits exceeded (reduce cpus/memory)
# - Template not found (daytona template list)
# - API key expired (daytona login)
```

### Command execution timeout

```bash
# Increase timeout in SDK
result = sandbox.process.exec("long-running-command", timeout=300)

# Or use background execution
sandbox.process.exec("nohup long-command > /tmp/out.log 2>&1 &")
# Poll for completion
import time
while True:
    result = sandbox.process.exec("cat /tmp/out.log")
    if "DONE" in result.stdout:
        break
    time.sleep(5)
```

### Port exposure not accessible

```bash
# Verify port is listening inside sandbox
daytona exec <sandbox-id> -- ss -tlnp | grep 8080

# Re-expose
daytona port remove <sandbox-id> 8080
daytona port expose <sandbox-id> 8080
```

### High costs

```bash
# List running sandboxes (vCPU/RAM billed)
daytona-helper.sh list | grep running

# Stop all running sandboxes
daytona list --json | jq -r '.[] | select(.state=="running") | .id' \
  | xargs -I{} daytona stop {}
```

## References

- **Docs**: https://docs.daytona.io
- **API Reference**: https://docs.daytona.io/api
- **Python SDK**: https://pypi.org/project/daytona-sdk/
- **TypeScript SDK**: https://www.npmjs.com/package/@daytonaio/sdk
- **GitHub**: https://github.com/daytonaio/daytona
- **Pricing**: https://www.daytona.io/pricing
- **Templates**: https://github.com/daytonaio/templates
