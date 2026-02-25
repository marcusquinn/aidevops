---
description: Remote container dispatch via SSH/Tailscale with credential forwarding and log collection
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Remote Container Dispatch

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `~/.aidevops/agents/scripts/remote-dispatch-helper.sh`
- **Config**: `~/.config/aidevops/remote-hosts.json`
- **Logs**: `~/.aidevops/.agent-workspace/supervisor/logs/remote/`
- **Task**: t1165.3

**What it does**: Dispatches AI workers to containers on remote hosts via SSH or Tailscale, with credential forwarding and log collection back to the local supervisor.

**When to use**:

- GPU-heavy tasks that need remote hardware
- Distributing work across multiple machines
- Running workers in isolated container environments
- Leveraging Tailscale mesh network for secure dispatch

**When NOT to use**:

- Local tasks (default dispatch handles these)
- Tasks that need local filesystem access
- Interactive development (use local TUI)

<!-- AI-CONTEXT-END -->

## Architecture

```text
Local Supervisor                    Remote Host
┌──────────────────┐               ┌──────────────────────┐
│  pulse.sh        │  SSH/Tailscale│  /tmp/aidevops-worker │
│  ├── dispatch.sh │──────────────>│  ├── t123/            │
│  │   └── remote- │  credentials │  │   ├── dispatch.sh   │
│  │      dispatch │  forwarding  │  │   ├── wrapper.sh    │
│  │      -helper  │               │  │   ├── worker.log   │
│  │               │<──────────────│  │   └── repo/         │
│  │   (log collect│  log stream  │  │       └── (git clone)│
│  │    on eval)   │               │  └── ...               │
│  └── evaluate.sh │               │                        │
│      (reads local│               │  Container (optional)  │
│       log copy)  │               │  ┌──────────────────┐  │
└──────────────────┘               │  │ docker exec ...   │  │
                                   │  └──────────────────┘  │
                                   └──────────────────────┘
```

## Host Configuration

### Add a Remote Host

```bash
# SSH host
remote-dispatch-helper.sh add gpu-server 192.168.1.100

# Tailscale host
remote-dispatch-helper.sh add build-node build-node.tailnet.ts.net --transport tailscale

# With specific user and container
remote-dispatch-helper.sh add docker-host 10.0.0.5 --user deploy --container worker-1

# SSH with custom port (use ssh:// URL)
remote-dispatch-helper.sh add staging ssh://deploy@staging.example.com:2222
```

### List and Remove Hosts

```bash
# List all configured hosts
remote-dispatch-helper.sh hosts

# Remove a host
remote-dispatch-helper.sh remove gpu-server
```

### Verify Connectivity

```bash
# Full connectivity check (SSH, Docker, AI CLI, agent forwarding, disk)
remote-dispatch-helper.sh check gpu-server
```

The check command verifies:

- SSH connectivity
- Docker/OrbStack availability
- AI CLI (opencode/claude) installation
- SSH agent forwarding
- Available disk space

## Dispatching Tasks

### Manual Dispatch

```bash
# Dispatch a task to a remote host
remote-dispatch-helper.sh dispatch t123 gpu-server \
  --model anthropic/claude-opus-4-6 \
  --description "Implement feature X"
```

### Supervisor Integration

The pulse supervisor dispatches workers to remote hosts via `remote-dispatch-helper.sh`. Use `target:hostname` tags in TODO.md or GitHub issue labels to route tasks to specific hosts.

> **Note**: The previous SQLite-based `supervisor.db` dispatch_target mechanism has been deprecated. The pulse supervisor uses GitHub as the state DB.

### TODO.md Integration

Future: Add `target:hostname` tag to TODO.md task lines for automatic dispatch_target population during task sync.

## Credential Forwarding

The remote dispatch system forwards credentials to remote workers:

| Credential | Method | Notes |
|-----------|--------|-------|
| SSH keys | SSH agent forwarding (`-A`) | Enables git push on remote |
| `GH_TOKEN` | Environment variable | For `gh` CLI operations |
| `ANTHROPIC_API_KEY` | Environment variable | For AI CLI |
| `OPENROUTER_API_KEY` | Environment variable | For model routing |
| `GOOGLE_API_KEY` | Environment variable | For Google AI models |

**Security notes**:

- SSH agent forwarding (`-A`) passes the local SSH agent socket, not the keys themselves
- API keys are passed as environment variables to the remote command
- Keys are NOT written to disk on the remote host
- The remote workspace is cleaned up after task completion

## Log Collection

### Stream Logs in Real-Time

```bash
# Follow logs as they're written
remote-dispatch-helper.sh logs t123 gpu-server --follow
```

### Collect Logs

```bash
# Download full log to local supervisor log directory
remote-dispatch-helper.sh logs t123 gpu-server

# Last 100 lines only
remote-dispatch-helper.sh logs t123 gpu-server --tail 100
```

### Automatic Collection

When the supervisor's pulse Phase 1 detects a remote worker has finished (PID no longer alive), it automatically:

1. Calls `remote-dispatch-helper.sh logs` to collect the remote log
2. Updates the task's `log_file` in the database to point to the local copy
3. Proceeds with normal evaluation using the local log copy

## Worker Status

```bash
# Check if remote worker is still running
remote-dispatch-helper.sh status t123 gpu-server
```

Shows: host, transport, container, PID, dispatch time, process state, completion signals, log size.

## Cleanup

```bash
# Clean up remote workspace (collects logs first)
remote-dispatch-helper.sh cleanup t123 gpu-server

# Clean up but keep logs on remote
remote-dispatch-helper.sh cleanup t123 gpu-server --keep-logs
```

## Transport: SSH vs Tailscale

| Feature | SSH | Tailscale |
|---------|-----|-----------|
| Setup | SSH keys + sshd | Tailscale installed on both ends |
| Network | Direct IP or hostname | Mesh network (100.x.x.x or *.ts.net) |
| NAT traversal | Requires port forwarding | Automatic |
| Auth | SSH keys / agent | Tailscale identity |
| Command | `ssh` | `tailscale ssh` (falls back to `ssh`) |

Tailscale is auto-detected for `*.ts.net` addresses and `100.x.x.x` IPs.

## Configuration File

The hosts configuration is stored in `~/.config/aidevops/remote-hosts.json`:

```json
{
  "hosts": {
    "gpu-server": {
      "address": "192.168.1.100",
      "transport": "ssh",
      "container": "auto",
      "user": "",
      "added": "2026-02-21T10:00:00Z"
    },
    "build-node": {
      "address": "build-node.tailnet.ts.net",
      "transport": "tailscale",
      "container": "worker-1",
      "user": "deploy",
      "added": "2026-02-21T10:00:00Z"
    }
  }
}
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE_DISPATCH_SSH_OPTS` | `-o ConnectTimeout=10 ...` | Extra SSH options |
| `REMOTE_DISPATCH_LOG_DIR` | `$SUPERVISOR_DIR/logs/remote` | Local log collection directory |
| `REMOTE_DISPATCH_HOSTS_FILE` | `~/.config/aidevops/remote-hosts.json` | Hosts config file |

## Troubleshooting

### SSH Connection Fails

```bash
# Test SSH manually
ssh -v user@host echo OK

# Check SSH agent
ssh-add -l

# For Tailscale, verify connectivity
tailscale status
tailscale ping hostname
```

### No AI CLI on Remote

The remote host needs `opencode` or `claude` CLI installed. Install via:

```bash
# On the remote host
npm install -g @anthropic-ai/claude-code
# or
curl -fsSL https://opencode.ai/install | bash
```

### Logs Not Collected

```bash
# Manual log collection
remote-dispatch-helper.sh logs t123 gpu-server

# Check remote log file exists
ssh user@host "ls -la /tmp/aidevops-worker/t123/worker.log"
```

### Worker Stuck

```bash
# Check status
remote-dispatch-helper.sh status t123 gpu-server

# Force cleanup
remote-dispatch-helper.sh cleanup t123 gpu-server
```
