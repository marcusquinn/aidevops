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

Agent for setting up, managing, identifying, and debugging cron jobs that dispatch AI agents. Uses OpenCode server API for session management.

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    Cron Agent System                         │
├─────────────────────────────────────────────────────────────┤
│  crontab                                                     │
│  └── cron-dispatch.sh <job-id>                              │
│      └── OpenCode Server API                                │
│          └── AI Session (executes task)                     │
│              └── Results → mail-helper.sh (optional)        │
├─────────────────────────────────────────────────────────────┤
│  Storage                                                     │
│  ├── ~/.config/aidevops/cron-jobs.json    (job definitions) │
│  ├── ~/.aidevops/.agent-workspace/cron/   (execution logs)  │
│  └── ~/.aidevops/.agent-workspace/mail/   (result delivery) │
└─────────────────────────────────────────────────────────────┘
```

## Commands

### List Jobs

```bash
# List all scheduled jobs
cron-helper.sh list

# Output:
# ID          Schedule        Task                          Status
# job-001     0 9 * * *       Run daily SEO report          active
# job-002     */30 * * * *    Check deployment health       active
# job-003     0 0 * * 0       Weekly backup verification    paused
```

### Add Job

```bash
# Add a new scheduled job
cron-helper.sh add \
  --schedule "0 9 * * *" \
  --task "Generate daily SEO report for example.com" \
  --name "daily-seo-report" \
  --notify mail \
  --timeout 300

# Options:
#   --schedule    Cron expression (required)
#   --task        Task description for AI (required)
#   --name        Human-readable name (optional, auto-generated)
#   --notify      Notification method: mail|none (default: none)
#   --timeout     Max execution time in seconds (default: 600)
#   --workdir     Working directory (default: current)
#   --model       Model to use (default: from config)
#   --paused      Create in paused state
```

### Remove Job

```bash
# Remove a job by ID
cron-helper.sh remove job-001

# Remove with confirmation skip
cron-helper.sh remove job-001 --force
```

### Pause/Resume

```bash
# Pause a job (keeps definition, removes from crontab)
cron-helper.sh pause job-001

# Resume a paused job
cron-helper.sh resume job-001
```

### View Logs

```bash
# View recent execution logs
cron-helper.sh logs

# View logs for specific job
cron-helper.sh logs --job job-001

# Tail logs in real-time
cron-helper.sh logs --tail 50 --follow

# View logs from specific date
cron-helper.sh logs --since "2024-01-15"
```

### Debug Job

```bash
# Debug a failing job
cron-helper.sh debug job-001

# Output:
# Job: job-001 (daily-seo-report)
# Schedule: 0 9 * * *
# Last run: 2024-01-15T09:00:00Z
# Status: FAILED
# Exit code: 1
# Duration: 45s
# 
# Error output:
# [ERROR] OpenCode server not responding on port 4096
# 
# Suggestions:
# 1. Ensure OpenCode server is running: opencode serve --port 4096
# 2. Check server health: curl http://localhost:4096/global/health
# 3. Verify OPENCODE_SERVER_PASSWORD if authentication is enabled
```

### Status

```bash
# Show overall cron system status
cron-helper.sh status

# Output:
# Cron Agent Status
# ─────────────────
# Jobs defined: 5
# Jobs active: 4
# Jobs paused: 1
# 
# OpenCode Server: running (port 4096)
# Last execution: 2024-01-15T09:00:00Z
# Failed jobs (24h): 1
# 
# Upcoming:
#   job-002 (health-check) in 15 minutes
#   job-001 (daily-seo-report) in 2 hours
```

## Job Configuration

Jobs are stored in `~/.config/aidevops/cron-jobs.json`:

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
      "model": "anthropic/claude-sonnet-4-20250514",
      "status": "active",
      "created": "2024-01-10T10:00:00Z",
      "lastRun": "2024-01-15T09:00:00Z",
      "lastStatus": "success"
    }
  ]
}
```

## Execution Flow

When a cron job triggers:

1. **crontab** calls `cron-dispatch.sh <job-id>`
2. **cron-dispatch.sh**:
   - Loads job config from `cron-jobs.json`
   - Checks OpenCode server health
   - Creates new session via API
   - Sends task prompt
   - Waits for completion (with timeout)
   - Logs results
   - Optionally sends notification via mailbox

```bash
# Example crontab entry (auto-managed)
0 9 * * * /Users/me/.aidevops/agents/scripts/cron-dispatch.sh job-001 >> /Users/me/.aidevops/.agent-workspace/cron/job-001.log 2>&1
```

## Integration with OpenCode Server

The cron agent requires OpenCode server to be running:

```bash
# Start server (recommended: use launchd/systemd for persistence)
opencode serve --port 4096

# With authentication (recommended for security)
OPENCODE_SERVER_PASSWORD=your-secret opencode serve --port 4096
```

### Persistent Server Setup (macOS)

Create `~/Library/LaunchAgents/com.aidevops.opencode-server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.aidevops.opencode-server</string>
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

Load with: `launchctl load ~/Library/LaunchAgents/com.aidevops.opencode-server.plist`

### Persistent Server Setup (Linux)

Create `~/.config/systemd/user/opencode-server.service`:

```ini
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

Enable with: `systemctl --user enable --now opencode-server`

## Use Cases

### Daily Reports

```bash
cron-helper.sh add \
  --schedule "0 9 * * *" \
  --task "Generate daily SEO performance report. Check rankings, traffic, and indexation status. Save to ~/reports/seo-$(date +%Y-%m-%d).md" \
  --name "daily-seo-report" \
  --notify mail
```

### Health Checks

```bash
cron-helper.sh add \
  --schedule "*/30 * * * *" \
  --task "Check deployment health for production servers. Verify SSL, response times, and error rates. Alert if issues found." \
  --name "health-check" \
  --timeout 120
```

### Automated Maintenance

```bash
cron-helper.sh add \
  --schedule "0 3 * * 0" \
  --task "Run weekly maintenance: prune old logs, consolidate memory, clean temp files. Report summary." \
  --name "weekly-maintenance" \
  --workdir "~/.aidevops"
```

### Content Publishing

```bash
cron-helper.sh add \
  --schedule "0 8 * * 1-5" \
  --task "Check content calendar for today's scheduled posts. Publish any ready content to WordPress and social media." \
  --name "content-publisher" \
  --workdir "~/projects/blog"
```

## Notification via Mailbox

When `--notify mail` is set, results are sent to the inter-agent mailbox:

```bash
# Check for cron job results
mail-helper.sh check --type status_report

# Results include:
# - Job ID and name
# - Execution time
# - Success/failure status
# - AI response summary
# - Any errors encountered
```

## Troubleshooting

### Job Not Running

```bash
# 1. Check crontab entry exists
crontab -l | grep cron-dispatch

# 2. Verify job is active (not paused)
cron-helper.sh list

# 3. Check cron daemon is running
pgrep cron || sudo service cron start
```

### OpenCode Server Issues

```bash
# 1. Check server is running
curl http://localhost:4096/global/health

# 2. Check authentication
curl -u admin:your-password http://localhost:4096/global/health

# 3. View server logs
tail -f /tmp/opencode-server.log
```

### Permission Issues

```bash
# Ensure scripts are executable
chmod +x ~/.aidevops/agents/scripts/cron-*.sh

# Check log directory permissions
ls -la ~/.aidevops/.agent-workspace/cron/
```

## Security Considerations

1. **Server authentication**: Always use `OPENCODE_SERVER_PASSWORD` for network-exposed servers
2. **Task validation**: Jobs only execute pre-defined tasks from `cron-jobs.json`
3. **Timeout limits**: All jobs have configurable timeouts to prevent runaway sessions
4. **Log rotation**: Old logs are automatically pruned (configurable retention)
5. **Credential isolation**: Tasks inherit environment from cron, not from config files

## Related Documentation

- `tools/ai-assistants/opencode-server.md` - OpenCode server API
- `mail-helper.sh` - Inter-agent mailbox for notifications
- `memory-helper.sh` - Cross-session memory for task context
- `workflows/ralph-loop.md` - Iterative AI development patterns
