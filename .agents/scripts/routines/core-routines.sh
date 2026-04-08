#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# core-routines.sh — Core routine definitions for seeding into routines repos.
# Sourced by init-routines-helper.sh. Do not execute directly.
#
# Each routine is defined as a function that outputs a markdown description
# to stdout. The TODO entry format and metadata are returned by
# get_core_routine_entries().

# ---------------------------------------------------------------------------
# get_core_routine_entries
# Outputs one line per core routine in pipe-delimited format:
#   id|enabled|title|schedule|estimate|script|type
# ---------------------------------------------------------------------------
get_core_routine_entries() {
	cat <<'ENTRIES'
r901|x|Supervisor pulse — dispatch tasks across repos|repeat:cron(*/2 * * * *)|~1m|scripts/pulse-wrapper.sh|script
r902|x|Auto-update — check for framework updates|repeat:cron(*/10 * * * *)|~30s|bin/aidevops-auto-update check|script
r903|x|Process guard — kill runaway processes|repeat:cron(*/1 * * * *)|~5s|scripts/process-guard-helper.sh kill-runaways|script
r904|x|Worker watchdog — monitor headless workers|repeat:cron(*/2 * * * *)|~10s|scripts/worker-watchdog.sh --check|script
r905|x|Memory pressure monitor|repeat:cron(*/1 * * * *)|~5s|scripts/memory-pressure-monitor.sh|script
r906|x|Repo sync — pull latest across repos|repeat:daily(@19:00)|~5m|bin/aidevops-repo-sync check|script
r907|x|Contribution watch — monitor FOSS activity|repeat:cron(0 * * * *)|~30s|scripts/contribution-watch-helper.sh scan|script
r908|x|Profile README update|repeat:cron(0 * * * *)|~30s|scripts/profile-readme-helper.sh update|script
r909|x|Screen time snapshot|repeat:cron(0 */6 * * *)|~10s|scripts/screen-time-helper.sh snapshot|script
r910|x|Skills sync — refresh agent skills|repeat:cron(*/5 * * * *)|~15s|bin/aidevops-skills-sync|script
r911|x|OAuth token refresh|repeat:cron(*/30 * * * *)|~10s|scripts/oauth-pool-helper.sh refresh|script
r912|x|Dashboard server|repeat:persistent|~0s|server/index.ts|service
ENTRIES
	return 0
}

# ---------------------------------------------------------------------------
# Core routine descriptions — one function per routine.
# Each outputs markdown to stdout.
# ---------------------------------------------------------------------------

describe_r901() {
	cat <<'DESC'
# r901: Supervisor pulse

## Overview

The heartbeat of aidevops autonomous operations. Every 2 minutes, the pulse
scans all `pulse: true` repos in `repos.json`, evaluates open tasks and issues,
and dispatches headless workers to implement them.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 2 minutes (`StartInterval: 120`) |
| Type | script |
| Expected duration | ~1 minute |
| Script | `scripts/pulse-wrapper.sh` |
| Plist | `com.aidevops.aidevops-supervisor-pulse` |

## What it does

1. Reads `repos.json` for pulse-enabled repos (respects `pulse_hours`, `pulse_expires`)
2. For each repo: checks open GitHub issues, TODO.md tasks, and enabled routines
3. Applies tier routing (`tier:simple` → Haiku, `tier:standard` → Sonnet, `tier:reasoning` → Opus)
4. Dispatches headless workers via `headless-runtime-helper.sh`
5. Enforces concurrency limits (max workers per repo, global cap)
6. Evaluates and dispatches due routines from `## Routines` sections

## What to check

- `~/.aidevops/.agent-workspace/cron/pulse/` — execution logs
- `launchctl list | grep supervisor-pulse` — PID and exit status
- `gh pr list` across pulse repos — PRs being created by workers
- `routine-log-helper.sh status` — last run metrics
DESC
	return 0
}

describe_r902() {
	cat <<'DESC'
# r902: Auto-update

## Overview

Keeps the aidevops framework current by checking for new versions every
10 minutes. When an update is available, runs `setup.sh --non-interactive`
to deploy new agents, scripts, and configurations without interrupting
active sessions.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 10 minutes (`StartInterval: 600`) |
| Type | script |
| Expected duration | ~30 seconds (check only), ~2 minutes (when updating) |
| Script | `bin/aidevops-auto-update check` |
| Plist | `com.aidevops.aidevops-auto-update` |

## What it does

1. Runs `git fetch` on the aidevops repo
2. Compares local HEAD with remote HEAD
3. If behind: pulls changes and runs `setup.sh --non-interactive`
4. Deploys updated agents, scripts, configs to `~/.aidevops/agents/`
5. Reports update status in the session greeting cache

## What to check

- Session greeting shows current version
- `~/.aidevops/agents/VERSION` — deployed version
- `git -C ~/Git/aidevops log --oneline -3` — recent updates
DESC
	return 0
}

describe_r903() {
	cat <<'DESC'
# r903: Process guard

## Overview

Prevents runaway AI processes from consuming excessive resources. Checks
every 30 seconds for processes that exceed time or memory limits and
terminates them gracefully.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 30 seconds (`StartInterval: 30`) |
| Type | script |
| Expected duration | ~5 seconds |
| Script | `scripts/process-guard-helper.sh kill-runaways` |
| Plist | `sh.aidevops.process-guard` |

## What it does

1. Scans for AI runtime processes (claude, opencode, node workers)
2. Checks wall-clock time against configurable limits
3. Checks memory usage against thresholds
4. Sends SIGTERM to processes exceeding limits (graceful shutdown)
5. Escalates to SIGKILL if process doesn't exit within grace period
6. Logs kills to `~/.aidevops/.agent-workspace/cron/process-guard/`

## What to check

- `~/.aidevops/.agent-workspace/cron/process-guard/` — kill logs
- `ps aux | grep -E 'claude|opencode'` — active processes
- System Activity Monitor — CPU/memory trends
DESC
	return 0
}

describe_r904() {
	cat <<'DESC'
# r904: Worker watchdog

## Overview

Monitors headless worker sessions dispatched by the pulse. Detects stalled,
crashed, or zombie workers and takes corrective action. Ensures workers
don't hold worktree locks indefinitely.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 2 minutes (`StartInterval: 120`) |
| Type | script |
| Expected duration | ~10 seconds |
| Script | `scripts/worker-watchdog.sh --check` |
| Plist | `sh.aidevops.worker-watchdog` |

## What it does

1. Reads active worker state from `~/.aidevops/.agent-workspace/tmp/`
2. Checks if worker PIDs are still alive
3. Detects stalled workers (no output for configurable timeout)
4. Cleans up orphaned worktree locks
5. Posts kill/timeout comments on GitHub issues for failed workers
6. Updates dispatch state so the pulse can retry

## What to check

- `~/.aidevops/.agent-workspace/tmp/session-*` — active worker sessions
- GitHub issue comments — kill notifications from watchdog
- `routine-log-helper.sh status` — watchdog run history
DESC
	return 0
}

describe_r905() {
	cat <<'DESC'
# r905: Memory pressure monitor

## Overview

Tracks system memory pressure to prevent OOM conditions during heavy
AI workloads. Logs memory snapshots and can trigger worker throttling
when pressure is high.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 60 seconds (`StartInterval: 60`) |
| Type | script |
| Expected duration | ~5 seconds |
| Script | `scripts/memory-pressure-monitor.sh` |
| Plist | `sh.aidevops.memory-pressure-monitor` |

## What it does

1. Reads macOS memory pressure level (nominal/warn/critical)
2. Logs memory statistics (free, active, wired, compressed)
3. At warn level: reduces pulse concurrency limits
4. At critical level: pauses new worker dispatches
5. Writes pressure state for other routines to read

## What to check

- `memory_pressure` command — current system pressure
- Activity Monitor → Memory tab — pressure graph
- `~/.aidevops/.agent-workspace/cron/memory-pressure/` — pressure logs
DESC
	return 0
}

describe_r906() {
	cat <<'DESC'
# r906: Repo sync

## Overview

Keeps all registered repos up to date by pulling latest changes daily.
Runs at 19:00 local time to sync before overnight pulse operations.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Daily at 19:00 (`StartCalendarInterval: Hour=19, Minute=0`) |
| Type | script |
| Expected duration | ~5 minutes (depends on repo count) |
| Script | `bin/aidevops-repo-sync check` |
| Plist | `sh.aidevops.repo-sync` |

## What it does

1. Reads all repos from `~/.config/aidevops/repos.json`
2. For each repo: `git fetch --all --prune`
3. For repos on default branch: `git pull --ff-only`
4. Reports repos that have diverged or have conflicts
5. Skips repos with uncommitted changes (safety)

## What to check

- `git -C <repo> log --oneline -3` — recent changes pulled
- `~/.config/aidevops/repos.json` — registered repos
- Repos with `local_only: true` are still synced locally (no fetch)
DESC
	return 0
}

describe_r907() {
	cat <<'DESC'
# r907: Contribution watch

## Overview

Monitors external FOSS repos where we've contributed (issues, PRs, comments).
Detects new activity that needs a reply — review requests, comment threads,
merge notifications.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every hour (`StartInterval: 3600`) |
| Type | script |
| Expected duration | ~30 seconds |
| Script | `scripts/contribution-watch-helper.sh scan` |
| Plist | `sh.aidevops.contribution-watch` |

## What it does

1. Reads repos with `contributed: true` from `repos.json`
2. Checks GitHub notifications for those repos
3. Filters for actionable items (review requests, mentions, replies)
4. Excludes managed `pulse: true` repos (handled by the pulse)
5. Reports items needing attention

## What to check

- `gh notification list` — pending notifications
- Repos with `contributed: true` in `repos.json`
- `~/.aidevops/.agent-workspace/cron/contribution-watch/` — scan logs
DESC
	return 0
}

describe_r908() {
	cat <<'DESC'
# r908: Profile README update

## Overview

Keeps the GitHub profile README current with recent activity, stats,
and project highlights. Runs hourly to reflect latest contributions.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every hour (`StartInterval: 3600`) |
| Type | script |
| Expected duration | ~30 seconds |
| Script | `scripts/profile-readme-helper.sh update` |
| Plist | `sh.aidevops.profile-readme-update` |

## What it does

1. Collects recent commit activity across repos
2. Gathers GitHub stats (contributions, streaks, languages)
3. Updates the profile README with current data
4. Commits and pushes if content changed

## What to check

- GitHub profile page — README content
- `git -C ~/Git/<username> log --oneline -3` — recent README updates
DESC
	return 0
}

describe_r909() {
	cat <<'DESC'
# r909: Screen time snapshot

## Overview

Captures periodic screen time data for productivity tracking and
session analytics. Runs every 6 hours.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 6 hours (`StartInterval: 21600`) |
| Type | script |
| Expected duration | ~10 seconds |
| Script | `scripts/screen-time-helper.sh snapshot` |
| Plist | `sh.aidevops.screen-time-snapshot` |

## What it does

1. Reads macOS Screen Time data (if accessible)
2. Captures active app usage durations
3. Logs development tool usage (IDE, terminal, browser)
4. Stores snapshots for trend analysis

## What to check

- System Settings → Screen Time — raw data
- `~/.aidevops/.agent-workspace/cron/screen-time/` — snapshot logs
DESC
	return 0
}

describe_r910() {
	cat <<'DESC'
# r910: Skills sync

## Overview

Refreshes agent skill definitions every 5 minutes. Ensures newly added
or updated skills are available to all runtimes without requiring a
full setup run.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 5 minutes (`StartInterval: 300`) |
| Type | script |
| Expected duration | ~15 seconds |
| Script | `bin/aidevops-skills-sync` |
| Plist | `sh.aidevops.skills-sync` |

## What it does

1. Checks for new or modified skill definitions in `~/.aidevops/agents/`
2. Regenerates SKILL.md files if source agents changed
3. Updates skill symlinks for runtime discovery
4. Lightweight — only processes changed files

## What to check

- `~/.config/Claude/skills/` — skill symlinks
- `ls ~/.aidevops/agents/*/SKILL.md` — generated skill files
DESC
	return 0
}

describe_r911() {
	cat <<'DESC'
# r911: OAuth token refresh

## Overview

Refreshes OAuth tokens for AI provider accounts (Anthropic, OpenAI) to
maintain authenticated sessions. Runs every 30 minutes to stay ahead
of token expiry.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 30 minutes (`StartInterval: 1800`) |
| Type | script |
| Expected duration | ~10 seconds |
| Script | `scripts/oauth-pool-helper.sh refresh` |
| Plist | `sh.aidevops.token-refresh` |

## What it does

1. Iterates through configured provider accounts
2. Checks token expiry timestamps
3. Refreshes tokens that are within the renewal window
4. Rotates to next account in pool if refresh fails
5. Updates credential store with new tokens

## What to check

- `oauth-pool-helper.sh status` — account pool health
- `~/.aidevops/.agent-workspace/cron/token-refresh/` — refresh logs
DESC
	return 0
}

describe_r912() {
	cat <<'DESC'
# r912: Dashboard server

## Overview

Persistent web dashboard providing a real-time view of aidevops operations —
repo health, worker status, routine metrics, and task progress.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Persistent (always running) |
| Type | service |
| Expected duration | Continuous |
| Script | `server/index.ts` |
| Plist | `com.aidevops.dashboard` |

## What it does

1. Serves a web UI on localhost
2. Aggregates data from repos.json, routine state, worker sessions
3. Displays real-time worker activity and pulse dispatch status
4. Shows routine execution history and health metrics
5. Provides quick links to GitHub issues and PRs

## What to check

- Browser: `http://localhost:<port>` — dashboard UI
- `launchctl list | grep dashboard` — process status
DESC
	return 0
}
