<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Repo Sync

Daily `git pull --ff-only` for repos in configured parent dirs. Fast-forwards clean, default-branch checkouts only. Skips dirty trees, non-default branches, no-remote repos, worktrees.

**CLI**: `aidevops repo-sync [enable|disable|status|check|dirs|config|logs]` — `check` for immediate one-shot.

**Scheduler**: macOS launchd (`~/Library/LaunchAgents/com.aidevops.aidevops-repo-sync.plist`); Linux cron (daily 3am).

**Disable**: `aidevops repo-sync disable`, `"repo_sync": false` in settings.json, or `AIDEVOPS_REPO_SYNC=false`. Interval: `AIDEVOPS_REPO_SYNC_INTERVAL=1440` (minutes, default daily).

**Parent dirs** (`~/.config/aidevops/repos.json`, default `~/Git`):

```bash
aidevops repo-sync dirs list           # Show configured directories
aidevops repo-sync dirs add ~/Projects # Add a parent directory
aidevops repo-sync dirs remove ~/Old   # Remove a parent directory
```

**Logs**: `~/.aidevops/logs/repo-sync.log` — `aidevops repo-sync logs [--tail N|--follow]`. **Status**: `aidevops repo-sync status`.

## Related

- `reference/services.md` — Services & Integrations index
