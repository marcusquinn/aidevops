---
description: Remote worker dispatch via SSH over any mesh (NetBird, Nostr VPN, WireGuard, Tailscale) with credential forwarding and log collection
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Remote Container Dispatch

## Quick Reference

| Item | Value |
|------|-------|
| Script | `~/.aidevops/agents/scripts/remote-dispatch-helper.sh` |
| Config | `~/.config/aidevops/remote-hosts.json` (fields: `address`, `transport`, `container`, `user`, `added`) |
| Logs | `~/.aidevops/.agent-workspace/supervisor/logs/remote/` |
| Task | t1165.3 |

**Use when**: GPU tasks, multi-machine distribution, isolated containers, dispatch over a private mesh (prefer self-hosted or decentralised: `reference/mesh-remote-workers.md`).
**Don't use when**: Local tasks, local filesystem access needed, interactive development.

For an explicitly isolated durable per-agent environment with create/start/exec/
stop/recover/destroy receipts, use `reference/agent-sandbox-lifecycle.md` and
`agent-sandbox-helper.sh`. Remote dispatch does not imply that sandbox contract.

## Architecture

`pulse.sh` → `dispatch.sh` → `remote-dispatch-helper.sh` — uploads a dispatch script via SSH stdin, clones the repo, and runs the worker in `/tmp/aidevops-worker/<task-id>/` on the remote host (optionally inside a Docker container via `docker exec`). Pulse Phase 1 detects worker exit (PID gone), collects logs back to the local supervisor, then runs normal evaluation.

## Host Management

```bash
remote-dispatch-helper.sh add gpu-server 192.168.1.100
remote-dispatch-helper.sh add mini mini.nvpn --user me                  # auto: nvpn
remote-dispatch-helper.sh add gpu peer.netbird.selfhosted --user me     # auto: netbird
remote-dispatch-helper.sh add build-node build-node.tailnet.ts.net --transport tailscale
remote-dispatch-helper.sh add docker-host 10.0.0.5 --user deploy --container worker-1
remote-dispatch-helper.sh add staging ssh://deploy@staging.example.com:2222
remote-dispatch-helper.sh hosts | remove <name> | check <name>  # check: SSH, Docker, AI CLI, disk
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

**Security**: SSH agent forwarding passes the socket, not keys. API keys are embedded in the dispatch script (uploaded via SSH stdin, no `AcceptEnv`/`SendEnv` dependency), never written as standalone files. On Linux, env vars are readable via `/proc/<pid>/environ` by same user/root while the worker runs — use short-lived tokens for sensitive deployments. Workspace cleaned up after completion.

## Monitoring and Cleanup

```bash
remote-dispatch-helper.sh logs t123 gpu-server [--follow|--tail 100]
remote-dispatch-helper.sh status t123 gpu-server   # host, transport, container, PID, state, log size
remote-dispatch-helper.sh cleanup t123 gpu-server [--keep-logs]
```

## Transports

Every transport uses SSH keys for authentication; the mesh only provides reachability. `--transport` is `ssh|netbird|nvpn|wireguard|tailscale`. Only `tailscale` changes the command (`tailscale ssh`, falling back to `ssh`); the others label diagnostics for failed checks. When omitted, the transport is detected:

| Address | Transport |
|---------|-----------|
| `*.nvpn` | `nvpn` |
| `*.netbird.selfhosted`, `*.netbird.cloud` | `netbird` |
| `*.ts.net` | `tailscale` |
| `100.64.0.0/10` listed by `tailscale status` / `netbird status -d` | `tailscale` / `netbird` (the range is shared, so it is never guessed) |
| anything else | `ssh` |

Non-login SSH shells miss nvm/bun/Homebrew installs. `check` and the dispatch script prepend common tool paths and load nvm, so nvm-installed `opencode` is found. Agent forwarding (`-A`) is on; register only hosts you trust as much as your workstation. Mesh choice and the OpenCode server pattern: `reference/mesh-remote-workers.md`.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE_DISPATCH_SSH_OPTS` | `-o ConnectTimeout=10 ...` | Extra SSH options |
| `REMOTE_DISPATCH_LOG_DIR` | `$SUPERVISOR_DIR/logs/remote` | Local log directory |
| `REMOTE_DISPATCH_HOSTS_FILE` | `~/.config/aidevops/remote-hosts.json` | Hosts config |

## Troubleshooting

| Problem | Commands |
|---------|----------|
| SSH fails | `ssh -v user@host echo OK` · `ssh-add -l` · mesh: `netbird status -d` / `nvpn status` / `wg show` / `tailscale status` |
| No AI CLI on remote | `npm install -g opencode-ai` or `curl -fsSL https://opencode.ai/install \| bash` · alt: `npm install -g @anthropic-ai/claude-code` |
| Logs not collected | `remote-dispatch-helper.sh logs t123 gpu-server` · `ssh user@host "ls -la /tmp/aidevops-worker/t123/worker.log"` |
| Worker stuck | `remote-dispatch-helper.sh status t123 gpu-server` · `remote-dispatch-helper.sh cleanup t123 gpu-server` |
