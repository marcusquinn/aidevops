<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Auto-Update

Polls GitHub every 10 min; runs `aidevops update` on new version. Safe during active sessions.

**CLI**: `aidevops auto-update [enable|disable|status|check|logs]`

**Scheduler**: macOS launchd (`~/Library/LaunchAgents/com.aidevops.auto-update.plist`); Linux cron. Auto-migrates existing cron on macOS.

**Disable**: `aidevops auto-update disable`, `"auto_update": false` in settings.json, or `AIDEVOPS_AUTO_UPDATE=false`. Priority: env > settings.json > default (`true`). **Logs**: `~/.aidevops/logs/auto-update.log`

**Skill refresh**: 24h-gated via `skill-update-helper.sh --auto-update --quiet`. Disable: `AIDEVOPS_SKILL_AUTO_UPDATE=false`. Frequency: `AIDEVOPS_SKILL_FRESHNESS_HOURS=<hours>` (default: 24).

**Upstream watch**: `upstream-watch-helper.sh check` — monitors external repos for new releases. Config: `.agents/configs/upstream-watch.json`. State: `~/.aidevops/cache/upstream-watch-state.json`. Commands: `status`, `check`, `ack <slug>`.

**Update behavior**: Shared agents overwritten on update. Only `custom/` and `draft/` preserved.

## Related

- `reference/services.md` — Services & Integrations index
