<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Inter-Agent Mailbox

SQLite-backed async messaging between parallel agent sessions.

**CLI**: `mail-helper.sh [send|check|read|archive|prune|status|register|deregister|agents|migrate]`

**Types**: task_dispatch, status_report, discovery, request, broadcast. Lifecycle: send → check → read → archive. `mail-helper.sh prune` for cleanup (`--force` deletes old archived).

**Runner integration**: Auto-check inbox before work, send status reports after. Unread messages prepended as context. TOON migration runs on `aidevops update`.

**Coordination caveat:** mailbox is async messaging, not a hard live lock. For dirty canonical worktrees, send a `request`/`broadcast` after creating a local dirty-worktree backup, but do not assume every interactive session will read it immediately. See `reference/dirty-worktree-preservation.md`.

## Related

- `reference/services.md` — Services & Integrations index
