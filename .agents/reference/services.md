# Services & Integrations — Detail Reference

Loaded on-demand when working with memory, mailbox, MCP, skills, auto-update, or repo-sync.
Core pointers are in `AGENTS.md`.

## Memory

Cross-session SQLite FTS5 memory. Commands: `/remember {content}`, `/recall {query}`, `/recall --recent`

**CLI**: `memory-helper.sh [store|recall|log|stats|prune|consolidate|export|graduate]`

**Session distillation**: `session-distill-helper.sh auto` (extract learnings at session end)

**Auto-capture log**: `/memory-log` or `memory-helper.sh log` (review auto-captured memories)

**Graduation**: `/graduate-memories` or `memory-graduate-helper.sh` — promote validated memories into shared docs so all users benefit. Memories qualify at high confidence or 3+ accesses.

**Semantic search** (opt-in): `memory-embeddings-helper.sh setup --provider local` enables vector similarity search. Use `--semantic` or `--hybrid` flags with recall for meaning-based search beyond keywords.

**Memory audit**: `memory-audit-pulse.sh run` — periodic hygiene (dedup, prune, graduate, scan for improvement opportunities). Runs automatically as Phase 9 of the supervisor pulse cycle.

**Namespaces**: Runners can have isolated memory via `--namespace <name>`. Use `--shared` to also search global memory. List with `memory-helper.sh namespaces`.

**Auto-recall**: Memories are automatically recalled at key entry points:
- **Interactive session start**: Recent memories (last 5) surface via conversation-starter.md
- **Session resume**: After loading checkpoint, recent memories provide context
- **Runner dispatch**: Before task execution, runners recall recent + task-specific memories
- **Objective runner**: On first step, recalls recent + objective-specific + failure pattern memories

Auto-recall is silent (no output if no memories found) and uses namespace isolation for runners.

**Full docs**: `reference/memory.md`

**Proactive memory**: When you detect solutions, preferences, workarounds, failed approaches, or decisions — proactively suggest `/remember {description}`. Use `memory-helper.sh store --auto` for auto-captured memories. Privacy: `<private>` blocks stripped, secrets rejected.

## Inter-Agent Mailbox

SQLite-backed async communication between parallel agent sessions.

**CLI**: `mail-helper.sh [send|check|read|archive|prune|status|register|deregister|agents|migrate]`

**Message types**: task_dispatch, status_report, discovery, request, broadcast

**Lifecycle**: send → check → read → archive (history preserved, prune is manual)

**Runner integration**: Runners automatically check inbox before work and send status reports after. Unread messages are prepended as context to the runner's prompt.

**Storage**: `mail-helper.sh prune` shows storage report. Use `--force` to delete old archived messages. Migration from TOON files runs automatically on `aidevops update`.

## MCP On-Demand Loading

MCPs disabled globally, enabled per-agent via YAML frontmatter.

**Discovery**: `mcp-index-helper.sh search "capability"` or `mcp-index-helper.sh get-mcp "tool-name"`

**Full docs**: `tools/context/mcp-discovery.md`

## Skills & Cross-Tool

Import community skills: `aidevops skill add <source>` (→ `*-skill.md` suffix)

**Discover skills**: `aidevops skills` or `/skills` in chat. Search, browse by category, get detailed descriptions, and get task-based recommendations.

**Commands**: `aidevops skills search <query>`, `aidevops skills browse <category>`, `aidevops skills describe <name>`, `aidevops skills categories`, `aidevops skills recommend "<task>"`, `aidevops skills list [--imported]`

**Online registry search**: Search the public [skills.sh](https://skills.sh/) registry for community skills:

```bash
aidevops skills search --registry "browser automation"
aidevops skills search --online "seo"
aidevops skills install vercel-labs/agent-browser@agent-browser
```

When local search returns no results, the `/skills` command suggests searching the public registry automatically.

**Cross-tool**: Claude marketplace plugin, Agent Skills (SKILL.md), Claude Code agents, manual AGENTS.md reference.

**Skill persistence**: Imported skills are stored in `~/.aidevops/agents/` and tracked in `configs/skill-sources.json`. The daily auto-update skill refresh (see Auto-Update below) keeps them current from upstream. Note: `aidevops update` overwrites shared agent files — only `custom/` and `draft/` survive. Re-import skills after an update, or place them in `custom/` for persistence.

**Full docs**: `scripts/commands/add-skill.md`, `scripts/commands/skills.md`

## Getting Started

**CLI**: `aidevops [init|update|auto-update|status|repos|skill|skills|detect|features|uninstall]`. See `/onboarding` for setup wizard.

## User Settings

Persistent user preferences are stored in `~/.config/aidevops/settings.json`. This file is optional — all keys default to sensible values. Environment variables always take priority over settings.json.

**Supported keys:**

| Key | Default | Description |
|-----|---------|-------------|
| `auto_update` | `true` | Enable/disable the auto-update launchd/cron job |
| `supervisor_pulse` | `true` | Enable/disable the supervisor pulse scheduler |
| `repo_sync` | `true` | Enable/disable the daily repo sync job |

**Example** — disable auto-update and supervisor pulse:

```json
{
  "auto_update": false,
  "supervisor_pulse": false
}
```

**Priority**: environment variable > settings.json > default (`true`).

**Shell access**: Scripts that source `shared-constants.sh` can read settings via `get_setting "key" "default"`.

## Contribution Watch

Monitors external issues/PRs for new activity needing reply, using the GitHub Notifications API. Managed repos (`pulse: true` in repos.json) are excluded to suppress internal automation noise.

**CLI**: `contribution-watch-helper.sh seed|scan|status|install|uninstall`

- `seed` — seed tracked threads from existing contributed repos
- `scan` — check for new activity on tracked threads (optional `--backfill` for low-frequency safety-net sweeps)
- `install` / `uninstall` — install/remove the scheduled scanner

**Security**: Automated scans are deterministic metadata checks (no LLM). Comment bodies are only shown in interactive sessions after `prompt-guard-helper.sh scan`.

## Auto-Update

Automatic polling for new releases. Checks GitHub every 10 minutes and runs `aidevops update` when a new version is available. Safe to run while AI sessions are active.

**CLI**: `aidevops auto-update [enable|disable|status|check|logs]`

**Enable**: `aidevops auto-update enable` (also offered during `setup.sh`)

**Disable**: `aidevops auto-update disable`

**Scheduler**: macOS uses launchd (`~/Library/LaunchAgents/com.aidevops.auto-update.plist`); Linux uses cron. Auto-migrates existing cron entries on macOS when `enable` is run.

**Config file**: `~/.config/aidevops/settings.json` — set `"auto_update": false` to persistently disable auto-update. This is the recommended way to opt out (survives shell restarts, no env var needed). The file is optional; all keys default to `true`.

**Env override**: `AIDEVOPS_AUTO_UPDATE=false` disables even if scheduler is installed. Env vars take priority over settings.json.

**Logs**: `~/.aidevops/logs/auto-update.log`

**Daily skill refresh**: Each auto-update check also runs a 24h-gated skill freshness check. If >24h have passed since the last check, `skill-update-helper.sh --auto-update --quiet` pulls upstream changes for all imported skills. State is tracked in `~/.aidevops/cache/auto-update-state.json` (`last_skill_check`, `skill_updates_applied`). Disable with `AIDEVOPS_SKILL_AUTO_UPDATE=false`; adjust frequency with `AIDEVOPS_SKILL_FRESHNESS_HOURS=<hours>` (default: 24). View skill check status with `aidevops auto-update status`.

**Upstream watch**: Alongside skill refresh, `upstream-watch-helper.sh check` monitors external repos we've borrowed ideas/code from for new releases. Unlike skill imports (code we pulled in) or contribution watch (repos we filed issues on), this tracks "inspiration repos" — repos we want to passively monitor for improvements relevant to our implementation. Config: `.agents/configs/upstream-watch.json`. State: `~/.aidevops/cache/upstream-watch-state.json`. Run `upstream-watch-helper.sh status` to see watched repos, `upstream-watch-helper.sh check` to check for updates, `upstream-watch-helper.sh ack <slug>` after reviewing.

**Repo version wins on update**: When `aidevops update` runs, shared agents in `~/.aidevops/agents/` are overwritten by the repo version. Only `custom/` and `draft/` directories are preserved. Imported skills stored outside these directories will be overwritten. To keep a skill across updates, either re-import it after each update or move it to `custom/`.

## Repo Sync

Automatic daily `git pull` for all git repos in configured parent directories. Keeps local clones up to date without manual intervention. Safe by design: only fast-forward pulls on clean, default-branch checkouts.

**CLI**: `aidevops repo-sync [enable|disable|status|check|dirs|config|logs]`

**Enable**: `aidevops repo-sync enable` (also offered during `/onboarding`)

**Disable**: `aidevops repo-sync disable`

**One-shot sync**: `aidevops repo-sync check` (runs immediately, no scheduler needed)

**Scheduler**: macOS uses launchd (`~/Library/LaunchAgents/com.aidevops.aidevops-repo-sync.plist`); Linux uses cron (daily at 3am).

**Config file**: `~/.config/aidevops/settings.json` — set `"repo_sync": false` to persistently disable. Env vars take priority.

**Env overrides**:

- `AIDEVOPS_REPO_SYNC=false` — disable even if scheduler is installed (overrides settings.json)
- `AIDEVOPS_REPO_SYNC_INTERVAL=1440` — minutes between syncs (default: 1440 = daily)

**Configuration** (`~/.config/aidevops/repos.json`):

```json
{"git_parent_dirs": ["~/Git", "~/Projects"]}
```

Default: `~/Git`. Manage with:

```bash
aidevops repo-sync dirs list           # Show configured directories
aidevops repo-sync dirs add ~/Projects # Add a parent directory
aidevops repo-sync dirs remove ~/Old   # Remove a parent directory
aidevops repo-sync config              # Show current config
```

**Safety**: Only runs `git pull --ff-only`. Skips repos with dirty working trees, repos not on their default branch, repos with no remote, and git worktrees (only main checkouts are synced).

**Logs**: `~/.aidevops/logs/repo-sync.log` — view with `aidevops repo-sync logs [--tail N]` or `aidevops repo-sync logs --follow`.

**Status**: `aidevops repo-sync status` — shows scheduler state, configured directories, and last sync results (pulled/skipped/failed counts).
