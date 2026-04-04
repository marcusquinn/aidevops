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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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
# Add a job
cron-helper.sh add \
  --schedule "0 9 * * *" \
  --task "Generate daily SEO report for example.com" \
  --name "daily-seo-report" \
  --notify mail \
  --timeout 300

# Options: --schedule (required), --task (required), --name, --notify mail|none,
#          --timeout (seconds, default 600), --workdir, --model, --paused

# Manage
cron-helper.sh list
cron-helper.sh remove <job-id> [--force]
cron-helper.sh pause <job-id>
cron-helper.sh resume <job-id>
cron-helper.sh status

# Logs and debug
cron-helper.sh logs [--job <id>] [--tail 50] [--follow] [--since "2024-01-15"]
cron-helper.sh debug <job-id>

# Check mail results (when --notify mail is set)
mail-helper.sh check --type status_report
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

Auto-managed crontab entry format:

```bash
0 9 * * * ~/.aidevops/agents/scripts/cron-dispatch.sh job-001 >> ~/.aidevops/.agent-workspace/cron/job-001.log 2>&1
```

## Persistent Server Setup

Full config templates: `tools/ai-assistants/opencode-server.md`.

**macOS (launchd)** — label `sh.aidevops.opencode-server`, plist `~/Library/LaunchAgents/sh.aidevops.opencode-server.plist`:

```bash
# Key fields: Label, ProgramArguments (/usr/local/bin/opencode serve --port 4096),
#             EnvironmentVariables (OPENCODE_SERVER_PASSWORD), RunAtLoad=true, KeepAlive=true
launchctl load ~/Library/LaunchAgents/sh.aidevops.opencode-server.plist
```

**Linux (systemd)** — `~/.config/systemd/user/opencode-server.service`:

```bash
# Key fields: ExecStart=/usr/local/bin/opencode serve --port 4096,
#             Environment=OPENCODE_SERVER_PASSWORD=your-secret-here, Restart=always
systemctl --user enable --now opencode-server
```

## Use Cases

```bash
# Daily SEO report (9am)
cron-helper.sh add --schedule "0 9 * * *" --name "daily-seo-report" --notify mail \
  --task "Generate daily SEO performance report. Check rankings, traffic, indexation. Save to ~/reports/seo-\$(date +%Y-%m-%d).md"

# Health check every 30 min
cron-helper.sh add --schedule "*/30 * * * *" --name "health-check" --timeout 120 \
  --task "Check deployment health. Verify SSL, response times, error rates. Alert if issues found."

# Weekly maintenance (Sunday 3am)
cron-helper.sh add --schedule "0 3 * * 0" --name "weekly-maintenance" --workdir "~/.aidevops" \
  --task "Run weekly maintenance: prune old logs, consolidate memory, clean temp files. Report summary."

# Weekday content publishing (8am Mon-Fri)
cron-helper.sh add --schedule "0 8 * * 1-5" --name "content-publisher" --workdir "~/projects/blog" \
  --task "Check content calendar for today's scheduled posts. Publish any ready content to WordPress and social media."
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
| HTTPS by default | Non-localhost hosts use HTTPS automatically (`localhost`/`127.0.0.1`/`::1` → HTTP) |
| Server auth | Always set `OPENCODE_SERVER_PASSWORD` for network-exposed servers |
| SSL verification | Enabled by default; `OPENCODE_INSECURE=1` only for self-signed certs |
| Task validation | Jobs only execute pre-defined tasks from `cron-jobs.json` |
| Timeouts | All jobs have configurable timeouts to prevent runaway sessions |
| Log rotation | Old logs auto-pruned (configurable retention) |
| Credential isolation | Tasks inherit environment from cron, not config files |

Remote server env vars: `OPENCODE_HOST`, `OPENCODE_PORT`, `OPENCODE_SERVER_PASSWORD`. Test with `cron-helper.sh status`.

## Related

- `tools/ai-assistants/opencode-server.md` — OpenCode server API and full plist/service templates
- `mail-helper.sh` — inter-agent mailbox for notifications
- `memory-helper.sh` — cross-session memory for task context
- `workflows/ralph-loop.md` — iterative AI development patterns
