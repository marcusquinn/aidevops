---
description: Cron job management for scheduled AI agent dispatch
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: true
---

# @cron - Scheduled Task Management

<!-- AI-CONTEXT-START -->

## Quick Reference

- **List jobs**: `cron-helper.sh list`
- **Add job**: `cron-helper.sh add --schedule "0 9 * * *" --task "Run daily report"`
- **Remove job**: `cron-helper.sh remove <job-id>`
- **Logs**: `cron-helper.sh logs [--job <id>] [--tail 50]`
- **Debug**: `cron-helper.sh debug <job-id>`
- **Status**: `cron-helper.sh status`
- **Config**: `~/.config/aidevops/cron-jobs.json`

<!-- AI-CONTEXT-END -->

Agent for setting up, managing, and debugging cron jobs that dispatch AI agents via the headless runtime helper.

## Architecture

```text
crontab → cron-dispatch.sh <job-id> → headless-runtime-helper.sh → AI Session → mail-helper.sh (optional)

Storage:
  ~/.config/aidevops/cron-jobs.json    (job definitions)
  ~/.aidevops/.agent-workspace/cron/   (execution logs)
  ~/.aidevops/.agent-workspace/mail/   (result delivery)
```

## Commands

```bash
# List all jobs
cron-helper.sh list

# Add a job
cron-helper.sh add \
  --schedule "0 9 * * *" \
  --task "Generate daily SEO report for example.com" \
  --name "daily-seo-report" \
  --notify mail \
  --timeout 300

# Options: --schedule (required), --task (required), --name, --notify mail|none,
#          --timeout (seconds, default 600), --workdir, --model, --paused

# Remove, pause, resume
cron-helper.sh remove <job-id> [--force]
cron-helper.sh pause <job-id>
cron-helper.sh resume <job-id>

# Logs
cron-helper.sh logs [--job <id>] [--tail 50] [--follow] [--since "2024-01-15"]

# Debug a failing job (shows last run, exit code, error output, suggestions)
cron-helper.sh debug <job-id>

# Overall status (job counts, last execution, upcoming)
cron-helper.sh status
```

## Job Configuration

`~/.config/aidevops/cron-jobs.json`:

```json
{
  "version": "1.0",
  "jobs": [
    {
      "id": "job-001",
      "name": "daily-seo-report",
      "schedule": "0 9 * * *",
      "task": "Generate daily SEO report for example.com using DataForSEO",
      "workdir": "/Users/me/projects/example-site",
      "timeout": 300,
      "notify": "mail",
      "model": "anthropic/claude-sonnet-4-6",
      "status": "active",
      "created": "2024-01-10T10:00:00Z",
      "lastRun": "2024-01-15T09:00:00Z",
      "lastStatus": "success"
    }
  ]
}
```

## Execution Flow

1. **crontab** calls `cron-dispatch.sh <job-id>`
2. **cron-dispatch.sh**: loads config → checks server health → creates session → sends task → waits (with timeout) → logs results → optionally notifies

```bash
# Auto-managed crontab entry format:
0 9 * * * ~/.aidevops/agents/scripts/cron-dispatch.sh job-001 >> ~/.aidevops/.agent-workspace/cron/job-001.log 2>&1
```

## Persistent Server Setup

### macOS (launchd)

Label: `sh.aidevops.opencode-server` | Plist: `~/Library/LaunchAgents/sh.aidevops.opencode-server.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>sh.aidevops.opencode-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/opencode</string>
        <string>serve</string>
        <string>--port</string>
        <string>4096</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OPENCODE_SERVER_PASSWORD</key>
        <string>your-secret-here</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/opencode-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/opencode-server.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/sh.aidevops.opencode-server.plist
```

### Linux (systemd)

```ini
# ~/.config/systemd/user/opencode-server.service
[Unit]
Description=OpenCode Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/opencode serve --port 4096
Environment=OPENCODE_SERVER_PASSWORD=your-secret-here
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now opencode-server
```

## Use Cases

```bash
# Daily SEO report
cron-helper.sh add --schedule "0 9 * * *" --name "daily-seo-report" --notify mail \
  --task "Generate daily SEO performance report. Check rankings, traffic, indexation. Save to ~/reports/seo-\$(date +%Y-%m-%d).md"

# Health check every 30 min
cron-helper.sh add --schedule "*/30 * * * *" --name "health-check" --timeout 120 \
  --task "Check deployment health for production servers. Verify SSL, response times, error rates. Alert if issues found."

# Weekly maintenance (Sunday 3am)
cron-helper.sh add --schedule "0 3 * * 0" --name "weekly-maintenance" --workdir "~/.aidevops" \
  --task "Run weekly maintenance: prune old logs, consolidate memory, clean temp files. Report summary."

# Weekday content publishing
cron-helper.sh add --schedule "0 8 * * 1-5" --name "content-publisher" --workdir "~/projects/blog" \
  --task "Check content calendar for today's scheduled posts. Publish any ready content to WordPress and social media."
```

## Notification via Mailbox

```bash
# Check results when --notify mail is set
mail-helper.sh check --type status_report
# Results include: job ID/name, execution time, success/failure, AI response summary, errors
```

## Troubleshooting

```bash
# Job not running
crontab -l | grep cron-dispatch    # verify entry exists
cron-helper.sh list                # verify job is active (not paused)
pgrep cron || sudo service cron start

# Server issues
curl http://localhost:4096/global/health
curl -u admin:your-password http://localhost:4096/global/health

# Permission issues
chmod +x ~/.aidevops/agents/scripts/cron-*.sh
ls -la ~/.aidevops/.agent-workspace/cron/
```

## Security

| Rule | Detail |
|------|--------|
| HTTPS by default | Non-localhost hosts use HTTPS automatically |
| Server auth | Always set `OPENCODE_SERVER_PASSWORD` for network-exposed servers |
| SSL verification | Enabled by default; `OPENCODE_INSECURE=1` only for self-signed certs |
| Task validation | Jobs only execute pre-defined tasks from `cron-jobs.json` |
| Timeouts | All jobs have configurable timeouts to prevent runaway sessions |
| Log rotation | Old logs auto-pruned (configurable retention) |
| Credential isolation | Tasks inherit environment from cron, not config files |

### Remote Server

```bash
export OPENCODE_HOST="opencode.example.com"
export OPENCODE_PORT="4096"
export OPENCODE_SERVER_PASSWORD="your-secure-password"
# export OPENCODE_INSECURE=1  # self-signed certs only, not for production
cron-helper.sh status  # test connection
```

| Host | Protocol |
|------|----------|
| `localhost`, `127.0.0.1`, `::1` | HTTP |
| Any other host | HTTPS |

## Related

- `tools/ai-assistants/opencode-server.md` — OpenCode server API
- `mail-helper.sh` — inter-agent mailbox for notifications
- `memory-helper.sh` — cross-session memory for task context
- `workflows/ralph-loop.md` — iterative AI development patterns
