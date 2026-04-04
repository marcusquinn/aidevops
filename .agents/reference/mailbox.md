<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Inter-Agent Mailbox

SQLite-backed async messaging between parallel agent sessions.

**CLI**: `mail-helper.sh [send|check|read|archive|prune|status|register|deregister|agents|migrate]`

**Types**: task_dispatch, status_report, discovery, request, broadcast. Lifecycle: send → check → read → archive. `mail-helper.sh prune` for cleanup (`--force` deletes old archived).

**Runner integration**: Auto-check inbox before work, send status reports after. Unread messages prepended as context. TOON migration runs on `aidevops update`.

## Related

- `reference/services.md` — Services & Integrations index
