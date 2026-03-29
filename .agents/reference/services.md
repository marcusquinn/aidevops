# Services & Integrations — Detail Reference

Loaded on-demand when working with memory, mailbox, MCP, skills, auto-update, or repo-sync.
Core pointers are in `AGENTS.md`.

## Memory

Cross-session SQLite FTS5 memory. Commands: `/remember {content}`, `/recall {query}`, `/recall --recent`

**CLI**: `memory-helper.sh [store|recall|log|stats|prune|consolidate|export|graduate]`

**Session distillation**: `session-distill-helper.sh auto` (extract learnings at session end)

**Auto-capture log**: `/memory-log` or `memory-helper.sh log`

**Graduation**: `/graduate-memories` or `memory-graduate-helper.sh` — promote validated memories (high confidence or 3+ accesses) into shared docs.

**Semantic search** (opt-in): `memory-embeddings-helper.sh setup --provider local`. Use `--semantic` or `--hybrid` flags with recall for meaning-based search.

**Memory audit**: `memory-audit-pulse.sh run` — periodic hygiene (dedup, prune, graduate). Runs as Phase 9 of supervisor pulse.

**Namespaces**: `--namespace <name>` for runner isolation, `--shared` to also search global. List: `memory-helper.sh namespaces`.

**Auto-recall**: Memories surface automatically at: interactive session start (last 5), session resume (after checkpoint), runner dispatch (task-specific), objective runner (objective + failure patterns). Silent when no memories found; uses namespace isolation for runners.

**Proactive memory**: Suggest `/remember {description}` when detecting solutions, preferences, workarounds, failed approaches, or decisions. Use `memory-helper.sh store --auto` for auto-captured. Privacy: `<private>` blocks stripped, secrets rejected.

**Full docs**: `reference/memory.md`

## Inter-Agent Mailbox

SQLite-backed async communication between parallel agent sessions.

**CLI**: `mail-helper.sh [send|check|read|archive|prune|status|register|deregister|agents|migrate]`

**Message types**: task_dispatch, status_report, discovery, request, broadcast

**Lifecycle**: send → check → read → archive. History preserved; `mail-helper.sh prune` for cleanup (`--force` to delete old archived).

**Runner integration**: Runners auto-check inbox before work and send status reports after. Unread messages prepended as context. Migration from TOON files runs on `aidevops update`.

## MCP On-Demand Loading

MCPs disabled globally, enabled per-agent via YAML frontmatter.

**Discovery**: `mcp-index-helper.sh search "capability"` or `mcp-index-helper.sh get-mcp "tool-name"`

**Full docs**: `tools/context/mcp-discovery.md`

## Skills & Cross-Tool

Import community skills: `aidevops skill add <source>` (→ `*-skill.md` suffix)

**Discover**: `aidevops skills` or `/skills`. Commands: `search <query>`, `browse <category>`, `describe <name>`, `categories`, `recommend "<task>"`, `list [--imported]`

**Online registry** ([skills.sh](https://skills.sh/)):

```bash
aidevops skills search --registry "browser automation"
aidevops skills install vercel-labs/agent-browser@agent-browser
```

When local search returns no results, `/skills` suggests the public registry automatically.

**Cross-tool**: Claude marketplace plugin, Agent Skills (SKILL.md), Claude Code agents, manual AGENTS.md reference.

**Persistence**: Imported skills stored in `~/.aidevops/agents/`, tracked in `configs/skill-sources.json`. Daily auto-update keeps them current. Only `custom/` and `draft/` survive `aidevops update` — re-import or place in `custom/` for persistence.

**Full docs**: `scripts/commands/add-skill.md`, `scripts/commands/skills.md`

## Getting Started

**CLI**: `aidevops [init|update|auto-update|status|repos|skill|skills|detect|features|uninstall]`. See `/onboarding` for setup wizard.

## User Settings

Persistent preferences in `~/.config/aidevops/settings.json` (optional — all keys default to `true`). Environment variables always take priority.

| Key | Default | Description |
|-----|---------|-------------|
| `auto_update` | `true` | Enable/disable the auto-update launchd/cron job |
| `supervisor_pulse` | `true` | Enable/disable the supervisor pulse scheduler |
| `repo_sync` | `true` | Enable/disable the daily repo sync job |

**Shell access**: Scripts sourcing `shared-constants.sh` use `get_setting "key" "default"`.

## Contribution Watch

Monitors external issues/PRs for new activity needing reply via GitHub Notifications API. Managed repos (`pulse: true`) excluded.

**CLI**: `contribution-watch-helper.sh seed|scan|status|install|uninstall`

- `seed` — seed tracked threads from contributed repos
- `scan` — check for new activity (`--backfill` for low-frequency safety-net sweeps)
- `install` / `uninstall` — manage scheduled scanner

**Security**: Scans are deterministic metadata checks (no LLM). Comment bodies shown only in interactive sessions after `prompt-guard-helper.sh scan`.

## FOSS Contributions

Per-repo etiquette controls and global daily token budget for FOSS contribution targets. Enforces rate limits and blocklists before dispatching.

**CLI**: `foss-contribution-helper.sh scan|check|budget|record|reset|status`

- `scan [--dry-run]` — list eligible FOSS repos (respects `labels_filter`, skips `blocklist: true`)
- `check <slug> [tokens]` — gate check (budget + rate limit + blocklist)
- `budget` — daily token usage vs ceiling
- `record <slug> <tokens>` — record usage after contribution
- `status` — all FOSS repos and config

**Config**: `config.jsonc` `foss` section — `enabled`, `max_daily_tokens`, `max_concurrent_contributions`.

**repos.json fields**: `foss: true`, `app_type`, `foss_config` (see `reference/foss-contributions.md`).

## Auto-Update

Polls GitHub every 10 minutes; runs `aidevops update` when new version available. Safe during active AI sessions.

**CLI**: `aidevops auto-update [enable|disable|status|check|logs]`

**Scheduler**: macOS launchd (`~/Library/LaunchAgents/com.aidevops.auto-update.plist`); Linux cron. Auto-migrates existing cron on macOS.

**Disable**: `aidevops auto-update disable`, or set `"auto_update": false` in settings.json, or `AIDEVOPS_AUTO_UPDATE=false` env var. Priority: env > settings.json > default (`true`).

**Logs**: `~/.aidevops/logs/auto-update.log`

**Daily skill refresh**: 24h-gated via `skill-update-helper.sh --auto-update --quiet`. State: `~/.aidevops/cache/auto-update-state.json` (`last_skill_check`, `skill_updates_applied`). Disable: `AIDEVOPS_SKILL_AUTO_UPDATE=false`. Frequency: `AIDEVOPS_SKILL_FRESHNESS_HOURS=<hours>` (default: 24). View: `aidevops auto-update status`.

**Upstream watch**: `upstream-watch-helper.sh check` monitors external repos we've borrowed from for new releases (distinct from skill imports and contribution watch). Config: `.agents/configs/upstream-watch.json`. State: `~/.aidevops/cache/upstream-watch-state.json`. Commands: `status`, `check`, `ack <slug>`.

**Update behavior**: Shared agents in `~/.aidevops/agents/` overwritten on update. Only `custom/` and `draft/` preserved.

## Repo Sync

Daily `git pull --ff-only` for all repos in configured parent directories. Only fast-forwards clean, default-branch checkouts. Skips dirty trees, non-default branches, no-remote repos, and worktrees.

**CLI**: `aidevops repo-sync [enable|disable|status|check|dirs|config|logs]`

**One-shot**: `aidevops repo-sync check` (immediate, no scheduler)

**Scheduler**: macOS launchd (`~/Library/LaunchAgents/com.aidevops.aidevops-repo-sync.plist`); Linux cron (daily 3am).

**Disable**: `aidevops repo-sync disable`, or `"repo_sync": false` in settings.json, or `AIDEVOPS_REPO_SYNC=false`. Interval: `AIDEVOPS_REPO_SYNC_INTERVAL=1440` (minutes, default daily).

**Parent dirs** (`~/.config/aidevops/repos.json`, default `~/Git`):

```bash
aidevops repo-sync dirs list           # Show configured directories
aidevops repo-sync dirs add ~/Projects # Add a parent directory
aidevops repo-sync dirs remove ~/Old   # Remove a parent directory
```

**Logs**: `~/.aidevops/logs/repo-sync.log` — `aidevops repo-sync logs [--tail N|--follow]`

**Status**: `aidevops repo-sync status` — scheduler state, directories, last sync results.
