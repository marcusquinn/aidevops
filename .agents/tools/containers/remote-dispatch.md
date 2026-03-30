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

| Item | Value |
|------|-------|
| Script | `~/.aidevops/agents/scripts/remote-dispatch-helper.sh` |
| Config | `~/.config/aidevops/remote-hosts.json` |
| Logs | `~/.aidevops/.agent-workspace/supervisor/logs/remote/` |
| Task | t1165.3 |

**Use when**: GPU tasks, multi-machine distribution, isolated containers, Tailscale mesh dispatch.
**Don't use when**: Local tasks, local filesystem access needed, interactive development.

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

## Host Management

```bash
# Add
remote-dispatch-helper.sh add gpu-server 192.168.1.100
remote-dispatch-helper.sh add build-node build-node.tailnet.ts.net --transport tailscale
remote-dispatch-helper.sh add docker-host 10.0.0.5 --user deploy --container worker-1
remote-dispatch-helper.sh add staging ssh://deploy@staging.example.com:2222

# List / remove / check
remote-dispatch-helper.sh hosts
remote-dispatch-helper.sh remove gpu-server
remote-dispatch-helper.sh check gpu-server   # verifies SSH, Docker, AI CLI, agent forwarding, disk
```

## Dispatching Tasks

```bash
remote-dispatch-helper.sh dispatch t123 gpu-server \
  --model anthropic/claude-opus-4-6 \
  --description "Implement feature X"
```

**Routing**: `target:hostname` label on GitHub issues or TODO.md tag. GitHub is the state DB (`supervisor.db` dispatch_target is deprecated).

## Credential Forwarding

| Credential | Method | Notes |
|-----------|--------|-------|
| SSH keys | SSH agent forwarding (`-A`) | Enables git push on remote |
| `GH_TOKEN` | Env var | For `gh` CLI |
| `ANTHROPIC_API_KEY` | Env var | For AI CLI |
| `OPENROUTER_API_KEY` | Env var | For model routing |
| `GOOGLE_API_KEY` | Env var | For Google AI models |

**Security**:
- SSH agent forwarding passes the socket, not keys
- API keys embedded in shell script uploaded via SSH stdin — no `AcceptEnv`/`SendEnv` dependency
- Keys exist only in the generated dispatch script, never as standalone files on disk
- Linux: env vars readable via `/proc/<pid>/environ` by same user + root while worker runs
- Sensitive deployments: restrict remote host access or use short-lived/scoped tokens
- Remote workspace cleaned up after task completion

## Log Collection

```bash
remote-dispatch-helper.sh logs t123 gpu-server           # download full log
remote-dispatch-helper.sh logs t123 gpu-server --follow  # stream in real-time
remote-dispatch-helper.sh logs t123 gpu-server --tail 100
```

**Auto-collection**: Pulse Phase 1 detects worker exit (PID gone) → calls `logs` → updates `log_file` in DB to local copy → normal evaluation.

## Status and Cleanup

```bash
remote-dispatch-helper.sh status t123 gpu-server    # host, transport, container, PID, state, log size
remote-dispatch-helper.sh cleanup t123 gpu-server   # collect logs then clean workspace
remote-dispatch-helper.sh cleanup t123 gpu-server --keep-logs
```

## Transport: SSH vs Tailscale

| Feature | SSH | Tailscale |
|---------|-----|-----------|
| Setup | SSH keys + sshd | Tailscale on both ends |
| Network | Direct IP/hostname | Mesh (100.x.x.x or *.ts.net) |
| NAT traversal | Requires port forwarding | Automatic |
| Auth | SSH keys / agent | Tailscale identity |
| Command | `ssh` | `tailscale ssh` (falls back to `ssh`) |

Tailscale auto-detected for `*.ts.net` and `100.x.x.x` addresses.

## Configuration (`~/.config/aidevops/remote-hosts.json`)

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
| `REMOTE_DISPATCH_LOG_DIR` | `$SUPERVISOR_DIR/logs/remote` | Local log directory |
| `REMOTE_DISPATCH_HOSTS_FILE` | `~/.config/aidevops/remote-hosts.json` | Hosts config |

## Troubleshooting

| Problem | Commands |
|---------|----------|
| SSH fails | `ssh -v user@host echo OK` · `ssh-add -l` · `tailscale status && tailscale ping hostname` |
| No AI CLI on remote | `npm install -g opencode-ai` or `curl -fsSL https://opencode.ai/install \| bash` · alt: `npm install -g @anthropic-ai/claude-code` |
| Logs not collected | `remote-dispatch-helper.sh logs t123 gpu-server` · `ssh user@host "ls -la /tmp/aidevops-worker/t123/worker.log"` |
| Worker stuck | `remote-dispatch-helper.sh status t123 gpu-server` · `remote-dispatch-helper.sh cleanup t123 gpu-server` |
