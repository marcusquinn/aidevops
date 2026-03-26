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
- **CLI**: `daytona` — install: `brew install daytonaio/tap/daytona` or `curl -sf -L https://download.daytona.io/daytona/install.sh | sudo bash`
- **API**: REST at `https://app.daytona.io/api` (Bearer token auth)
- **Helper**: `daytona-helper.sh [create|start|stop|destroy|list|exec|snapshot|status] [args]`
- **Auth**: `daytona login` (browser) or `export DAYTONA_API_KEY="..."` + `aidevops secret set DAYTONA_API_KEY`
- **Billing**: Per-second, resource-based (vCPU + RAM + disk). Stopped sandboxes: disk only.
- **Isolation**: gVisor kernel-level sandbox per workspace

**Use cases**: AI agent code execution, CI/CD ephemeral runners, preview environments, LLM tool-use sandboxes

<!-- AI-CONTEXT-END -->

Daytona provides cloud-hosted, ephemeral development environments (sandboxes) optimised for AI agent workflows. Each sandbox is a fully isolated Linux environment with per-second billing, stateful snapshots, and a REST/SDK API for programmatic lifecycle management.

## Sandbox Lifecycle

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

**Resource limits**: vCPU 2–64, RAM 4–256 GB, Disk 10–500 GB, GPU optional (A100/H100/L40S).

```bash
# Custom resources
daytona create --cpus 8 --memory 32 --disk 100 --gpu a100-80gb

# GPU types: a100-80gb | h100-80gb | l40s-48gb
daytona create --template python-3.11 --gpu h100-80gb --memory 64
daytona exec <sandbox-id> -- nvidia-smi
```

## Workspace Templates

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

**Threat model**: Safe for executing untrusted LLM-generated code. Not a substitute for application-level input validation.

## AI Agent Integration Patterns

### Code Execution Sandbox

```python
from daytona_sdk import Daytona, CreateSandboxParams
import os

daytona = Daytona(api_key=os.environ["DAYTONA_API_KEY"])

def execute_agent_code(code: str) -> dict:
    sandbox = daytona.create(CreateSandboxParams(language="python", template="python-3.11"))
    try:
        sandbox.process.exec(f"cat > /tmp/code.py << 'EOF'\n{code}\nEOF")
        result = sandbox.process.exec("python /tmp/code.py", timeout=60)
        return {"stdout": result.stdout, "stderr": result.stderr, "exit_code": result.exit_code}
    finally:
        daytona.destroy(sandbox.id)
```

### Persistent Dev Environment

```bash
SANDBOX_ID=$(daytona-helper.sh create dev-env --template python-3.11)
daytona-helper.sh stop "$SANDBOX_ID"          # save vCPU/RAM cost
daytona-helper.sh start "$SANDBOX_ID"         # resume later
daytona-helper.sh exec "$SANDBOX_ID" "python my_script.py"
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

### Python

```python
from daytona_sdk import Daytona, CreateSandboxParams, SandboxState

daytona = Daytona(api_key=os.environ["DAYTONA_API_KEY"])

sandbox = daytona.create(CreateSandboxParams(
    language="python", template="python-3.11",
    resources={"cpus": 2, "memory": 4, "disk": 10},
    env_vars={"MY_VAR": "value"},
    labels={"project": "my-app"},
))

daytona.start(sandbox.id)
daytona.stop(sandbox.id)
daytona.destroy(sandbox.id)

result = sandbox.process.exec("ls -la", timeout=10)
sandbox.filesystem.write("/tmp/script.py", "print('hello')")
content = sandbox.filesystem.read("/tmp/output.txt")

running = [s for s in daytona.list() if s.state == SandboxState.RUNNING]
```

### TypeScript

```typescript
import { Daytona } from "@daytonaio/sdk";

const daytona = new Daytona({ apiKey: process.env.DAYTONA_API_KEY });
const sandbox = await daytona.create({ language: "typescript", template: "node-20",
  resources: { cpus: 2, memory: 4, disk: 10 }, envVars: { NODE_ENV: "test" } });
const result = await sandbox.process.exec("npm test", { timeout: 120 });
await daytona.destroy(sandbox.id);
```

## REST API

Base URL: `https://app.daytona.io/api` — `Authorization: Bearer $DAYTONA_API_KEY`

```bash
AUTH="Authorization: Bearer $DAYTONA_API_KEY"
curl -H "$AUTH" https://app.daytona.io/api/sandboxes                                          # list
curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"template":"python-3.11","resources":{"cpus":2,"memory":4,"disk":10}}' \
  https://app.daytona.io/api/sandboxes                                                        # create
curl -X POST -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>/start                      # start
curl -X POST -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>/stop                       # stop
curl -X DELETE -H "$AUTH" https://app.daytona.io/api/sandboxes/<id>                          # destroy
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

**Choose Daytona**: stateful sandboxes with snapshots, GPU, or stop/start lifecycle.
**Choose E2B**: purely ephemeral sandboxes, simpler API, no persistence needed.
**Choose Modal**: serverless GPU functions, not interactive sandboxes.

## Troubleshooting

```bash
# Sandbox fails to start
daytona-helper.sh status <sandbox-id>
daytona logs <sandbox-id>
# Causes: resource limits exceeded, template not found, API key expired

# Command timeout — increase or use background + poll
result = sandbox.process.exec("long-running-command", timeout=300)
# Background execution with polling:
proc = sandbox.process.exec_async("long-running-command")
while not proc.is_done():
    time.sleep(5)
result = proc.wait()

# Port not accessible — verify listening, then re-expose
daytona exec <sandbox-id> -- ss -tlnp | grep 8080
daytona port remove <sandbox-id> 8080 && daytona port expose <sandbox-id> 8080

# High costs — stop running sandboxes
daytona list --json | jq -r '.[] | select(.state=="running") | .id' | xargs -I{} daytona stop {}
```

## References

- **Docs**: https://docs.daytona.io
- **API**: https://docs.daytona.io/api
- **Python SDK**: https://pypi.org/project/daytona-sdk/
- **TypeScript SDK**: https://www.npmjs.com/package/@daytonaio/sdk
- **GitHub**: https://github.com/daytonaio/daytona
- **Pricing**: https://www.daytona.io/pricing
- **Templates**: https://github.com/daytonaio/templates
