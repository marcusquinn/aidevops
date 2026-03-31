# Services & Integrations — Detail Reference

Core pointers in `AGENTS.md`. Load on-demand for memory, mailbox, MCP, skills, auto-update, or repo-sync.

## Memory

Cross-session SQLite FTS5. Commands: `/remember {content}`, `/recall {query}`, `/recall --recent`

**CLI**: `memory-helper.sh [store|recall|log|stats|prune|consolidate|export|graduate]`

**Distillation**: `session-distill-helper.sh auto` at session end. **Auto-capture**: `/memory-log` or `memory-helper.sh log`.

**Graduation**: `/graduate-memories` or `memory-graduate-helper.sh` — promotes high-confidence or 3+-access memories into shared docs.

**Semantic search** (opt-in): `memory-embeddings-helper.sh setup --provider local`. Use `--semantic` or `--hybrid` with recall. **Audit**: `memory-audit-pulse.sh run` — dedup, prune, graduate (Phase 9 of supervisor pulse).

**Namespaces**: `--namespace <name>` for runner isolation, `--shared` for global. List: `memory-helper.sh namespaces`.

**Auto-recall**: Surfaces at session start (last 5), resume, runner dispatch (task-specific), objective runner (objective + failure patterns). Silent when empty; namespace-isolated for runners.

**Proactive**: Suggest `/remember` on solutions, preferences, workarounds, failed approaches, decisions. `memory-helper.sh store --auto` for auto-captured. Privacy: `<private>` blocks stripped, secrets rejected.

**Full docs**: `reference/memory.md`

## Inter-Agent Mailbox

SQLite-backed async messaging between parallel agent sessions.

**CLI**: `mail-helper.sh [send|check|read|archive|prune|status|register|deregister|agents|migrate]`

**Types**: task_dispatch, status_report, discovery, request, broadcast. Lifecycle: send → check → read → archive. `mail-helper.sh prune` for cleanup (`--force` deletes old archived).

**Runner integration**: Auto-check inbox before work, send status reports after. Unread messages prepended as context. TOON migration runs on `aidevops update`.

## MCP On-Demand Loading

MCPs disabled globally, enabled per-agent via YAML frontmatter.

**Discovery**: `mcp-index-helper.sh search "capability"` or `mcp-index-helper.sh get-mcp "tool-name"`. **Full docs**: `tools/context/mcp-discovery.md`

## Skills & Cross-Tool

Import: `aidevops skill add <source>` (→ `*-skill.md` suffix)

**Discover**: `aidevops skills` or `/skills`. Subcommands: `search`, `browse`, `describe`, `categories`, `recommend`, `list [--imported]`

**Online registry** ([skills.sh](https://skills.sh/)):

```bash
aidevops skills search --registry "browser automation"
aidevops skills install vercel-labs/agent-browser@agent-browser
```

Local search with no results → `/skills` suggests the public registry automatically.

**Persistence**: `~/.aidevops/agents/`, tracked in `configs/skill-sources.json`. Daily auto-update. Only `custom/` and `draft/` survive `aidevops update`.

**Full docs**: `scripts/commands/add-skill.md`, `scripts/commands/skills.md`

## User Settings

`~/.config/aidevops/settings.json` (optional; all keys default `true`). Env vars take priority.

| Key | Default | Description |
|-----|---------|-------------|
| `auto_update` | `true` | Auto-update launchd/cron |
| `supervisor_pulse` | `true` | Supervisor pulse scheduler |
| `repo_sync` | `true` | Daily repo sync |

**Shell access**: `shared-constants.sh` → `get_setting "key" "default"`.

## Contribution Watch

Monitors external issues/PRs via GitHub Notifications API. Managed repos (`pulse: true`) excluded.

**CLI**: `contribution-watch-helper.sh seed|scan|status|install|uninstall`

- `seed` — seed tracked threads from contributed repos
- `scan` — check for new activity (`--backfill` for safety-net sweeps)
- `install` / `uninstall` — manage scheduled scanner

**Security**: Deterministic metadata checks (no LLM). Comment bodies shown only in interactive sessions after `prompt-guard-helper.sh scan`.

## FOSS Contributions

Per-repo etiquette controls and global daily token budget. Enforces rate limits and blocklists before dispatching.

**CLI**: `foss-contribution-helper.sh scan|check|budget|record|reset|status`

- `scan [--dry-run]` — eligible repos (respects `labels_filter`, skips `blocklist: true`)
- `check <slug> [tokens]` — gate check (budget + rate limit + blocklist)
- `budget` — daily token usage vs ceiling
- `record <slug> <tokens>` — record usage after contribution
- `status` — all FOSS repos and config

**Config**: `config.jsonc` `foss` section — `enabled`, `max_daily_tokens`, `max_concurrent_contributions`. **repos.json**: `foss: true`, `app_type`, `foss_config` (see `reference/foss-contributions.md`).

## Auto-Update

Polls GitHub every 10 min; runs `aidevops update` on new version. Safe during active sessions.

**CLI**: `aidevops auto-update [enable|disable|status|check|logs]`

**Scheduler**: macOS launchd (`~/Library/LaunchAgents/com.aidevops.auto-update.plist`); Linux cron. Auto-migrates existing cron on macOS.

**Disable**: `aidevops auto-update disable`, `"auto_update": false` in settings.json, or `AIDEVOPS_AUTO_UPDATE=false`. Priority: env > settings.json > default (`true`). **Logs**: `~/.aidevops/logs/auto-update.log`

**Skill refresh**: 24h-gated via `skill-update-helper.sh --auto-update --quiet`. Disable: `AIDEVOPS_SKILL_AUTO_UPDATE=false`. Frequency: `AIDEVOPS_SKILL_FRESHNESS_HOURS=<hours>` (default: 24).

**Upstream watch**: `upstream-watch-helper.sh check` — monitors external repos for new releases. Config: `.agents/configs/upstream-watch.json`. State: `~/.aidevops/cache/upstream-watch-state.json`. Commands: `status`, `check`, `ack <slug>`.

**Update behavior**: Shared agents overwritten on update. Only `custom/` and `draft/` preserved.

## Repo Sync

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
