<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Repo Sync

Daily read-only drift report for repos in configured parent dirs. It never fetches, pulls or otherwise changes canonical checkouts: it compares each clean, default-branch checkout with `git ls-remote` and logs `OK` (up to date) or `STALE` (remote drift). Skips dirty trees, non-default branches, no-remote repos, worktrees. A `STALE` line marked `CONVERGENCE_ELIGIBLE` includes the audited `canonical-recovery-helper.sh sync-mirror` command to converge it. A `STALE` line saying ancestry is unverified or diverged has no command: inspect that checkout by hand (`git fetch`, then compare with the remote default branch) before changing it.

**CLI**: `aidevops repo-sync [enable|disable|status|check|dirs|config|logs]` — `check` for immediate one-shot.

**Scheduler**: macOS launchd (`~/Library/LaunchAgents/sh.aidevops.repo-sync.plist`); Linux systemd user timer, falling back to cron (daily 3am).

**Disable**: `aidevops repo-sync disable` (removes the scheduler) or `AIDEVOPS_REPO_SYNC=false` (skips each check). `aidevops config set orchestration.repo_sync false` only stops `setup.sh` from installing the scheduler; it does not stop an installed one. Interval: `AIDEVOPS_REPO_SYNC_INTERVAL=1440` (minutes, default daily).

**Parent dirs** (`~/.config/aidevops/repos.json`, default `~/Git`):

```bash
aidevops repo-sync dirs list           # Show configured directories
aidevops repo-sync dirs add ~/Projects # Add a parent directory
aidevops repo-sync dirs remove ~/Old   # Remove a parent directory
```

**Logs**: `~/.aidevops/logs/repo-sync.log` — `aidevops repo-sync logs [--tail N|--follow]`. **Status**: `aidevops repo-sync status`.

## Related

- `reference/services.md` — Services & Integrations index
