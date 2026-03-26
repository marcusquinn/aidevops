# aidevops Settings Reference

## Overview

`~/.config/aidevops/settings.json` is the canonical configuration file for aidevops. All settings configurable via `/onboarding` are also readable and writable in this file.

**File location**: `~/.config/aidevops/settings.json`
**Helper script**: `~/.aidevops/agents/scripts/settings-helper.sh`
**Created by**: `setup.sh` on first run, or `settings-helper.sh init`

## Precedence

Settings are resolved with this precedence (highest wins):

1. **Environment variable** (`AIDEVOPS_*`) -- always wins
2. **settings.json** value -- persistent user config
3. **Built-in default** -- hardcoded in settings-helper.sh

This means you can always override any setting temporarily via env var without editing the file. Useful for CI/CD, testing, or one-off runs.

## Settings Reference

### auto_update

Controls automatic update behavior for aidevops, skills, tools, and OpenClaw.

| Key | Type | Default | Env Var | Description |
|-----|------|---------|---------|-------------|
| `auto_update.enabled` | boolean | `true` | `AIDEVOPS_AUTO_UPDATE` | Master switch for auto-update. Set `false` to disable all automatic updates. |
| `auto_update.interval_minutes` | number | `10` | `AIDEVOPS_UPDATE_INTERVAL` | Minutes between update checks. Range: 1-1440. |
| `auto_update.skill_auto_update` | boolean | `true` | `AIDEVOPS_SKILL_AUTO_UPDATE` | Enable daily skill freshness checks. Skills are imported agent packages that may have upstream updates. |
| `auto_update.skill_freshness_hours` | number | `24` | `AIDEVOPS_SKILL_FRESHNESS_HOURS` | Hours between skill freshness checks. |
| `auto_update.tool_auto_update` | boolean | `true` | `AIDEVOPS_TOOL_AUTO_UPDATE` | Enable periodic tool updates (npm, brew, pip packages). Only runs when user is idle. |
| `auto_update.tool_freshness_hours` | number | `6` | `AIDEVOPS_TOOL_FRESHNESS_HOURS` | Hours between tool freshness checks. |
| `auto_update.tool_idle_hours` | number | `6` | `AIDEVOPS_TOOL_IDLE_HOURS` | Required user idle time (hours) before tool updates run. Prevents updates during active work. |
| `auto_update.openclaw_auto_update` | boolean | `true` | `AIDEVOPS_OPENCLAW_AUTO_UPDATE` | Enable daily OpenClaw update checks (only if openclaw CLI is installed). |
| `auto_update.openclaw_freshness_hours` | number | `24` | `AIDEVOPS_OPENCLAW_FRESHNESS_HOURS` | Hours between OpenClaw update checks. |
| `auto_update.upstream_watch` | boolean | `true` | `AIDEVOPS_UPSTREAM_WATCH` | Enable daily upstream repo watch checks. Monitors external repos for new releases. |
| `auto_update.upstream_watch_hours` | number | `24` | `AIDEVOPS_UPSTREAM_WATCH_HOURS` | Hours between upstream watch checks. |

### supervisor

Controls the autonomous orchestration supervisor that dispatches AI workers.

| Key | Type | Default | Env Var | Description |
|-----|------|---------|---------|-------------|
| `supervisor.pulse_enabled` | boolean | `true` | `AIDEVOPS_SUPERVISOR_PULSE` | Enable the supervisor pulse scheduler. When enabled, dispatches workers every `pulse_interval_seconds`. |
| `supervisor.pulse_interval_seconds` | number | `120` | -- | Seconds between pulse cycles. Range: 30-3600. |
| `supervisor.stale_threshold_seconds` | number | `1800` | -- | Seconds before a worker is considered stale/stuck. |
| `supervisor.circuit_breaker_max_failures` | number | `3` | -- | Consecutive worker failures before the circuit breaker pauses dispatch. |
| `supervisor.strategic_review_hours` | number | `4` | -- | Hours between opus-tier strategic reviews of queue health. |
| `supervisor.peak_hours_enabled` | boolean | `false` | `AIDEVOPS_PEAK_HOURS_ENABLED` | Enable peak-hours worker cap. When `true`, `MAX_WORKERS` is reduced during the configured window. **Disabled by default.** |
| `supervisor.peak_hours_start` | number | `5` | `AIDEVOPS_PEAK_HOURS_START` | Start hour of the peak window (0-23, local time). Default 5 = 5 AM. |
| `supervisor.peak_hours_end` | number | `11` | `AIDEVOPS_PEAK_HOURS_END` | End hour of the peak window (0-23, local time, exclusive). Default 11 = 11 AM. Overnight windows supported (start > end, e.g., `22` → `6`). |
| `supervisor.peak_hours_tz` | string | `"America/Los_Angeles"` | `AIDEVOPS_PEAK_HOURS_TZ` | Timezone label for documentation. The pulse uses system local time (`date +%H`), so set your system timezone to match. |
| `supervisor.peak_hours_worker_fraction` | number | `0.2` | `AIDEVOPS_PEAK_HOURS_WORKER_FRACTION` | Fraction of off-peak `MAX_WORKERS` allowed during peak hours. `0.2` = 20%. Result is rounded up, minimum 1. |

### repo_sync

Controls daily git repository synchronization.

| Key | Type | Default | Env Var | Description |
|-----|------|---------|---------|-------------|
| `repo_sync.enabled` | boolean | `true` | `AIDEVOPS_REPO_SYNC` | Enable daily `git pull --ff-only` on clean repos. |
| `repo_sync.schedule` | string | `"daily"` | -- | Sync schedule. Currently only `daily` is supported. |

### quality

Controls code quality tools and linting behavior.

| Key | Type | Default | Env Var | Description |
|-----|------|---------|---------|-------------|
| `quality.shellcheck_enabled` | boolean | `true` | -- | Run ShellCheck on shell scripts. |
| `quality.sonarcloud_enabled` | boolean | `true` | -- | Run SonarCloud analysis. |
| `quality.write_time_linting` | boolean | `true` | -- | Lint files immediately after each edit (not just at commit time). |

### model_routing

Controls AI model selection and cost management.

| Key | Type | Default | Env Var | Description |
|-----|------|---------|---------|-------------|
| `model_routing.default_tier` | string | `"sonnet"` | -- | Default model tier for tasks without explicit tier. Options: `haiku`, `sonnet`, `opus`, `flash`, `pro`. |
| `model_routing.budget_tracking_enabled` | boolean | `true` | -- | Track per-provider API spend. |
| `model_routing.prefer_subscription` | boolean | `true` | -- | Prefer subscription plans over API billing when both are available. |

### onboarding

Tracks onboarding state. Written by `/onboarding`, readable by scripts.

| Key | Type | Default | Env Var | Description |
|-----|------|---------|---------|-------------|
| `onboarding.completed` | boolean | `false` | -- | Whether the user has completed `/onboarding`. |
| `onboarding.work_type` | string | `""` | -- | User's primary work type (e.g., `"web"`, `"devops"`, `"seo"`, `"wordpress"`). |
| `onboarding.familiarity` | array | `[]` | -- | Concepts the user is familiar with (e.g., `["git", "terminal", "api_keys"]`). |

### ui

Controls terminal output behavior.

| Key | Type | Default | Env Var | Description |
|-----|------|---------|---------|-------------|
| `ui.color_output` | boolean | `true` | -- | Enable colored terminal output. |
| `ui.verbose` | boolean | `false` | -- | Enable verbose/debug output in scripts. |

## Usage Examples

### CLI

```bash
# Create settings file with defaults
settings-helper.sh init

# Disable auto-update
settings-helper.sh set auto_update.enabled false

# Check a setting
settings-helper.sh get auto_update.interval_minutes

# List all settings
settings-helper.sh list

# Validate settings file
settings-helper.sh validate

# Export as env vars for shell sourcing
eval "$(settings-helper.sh export-env)"
```

### Direct JSON editing

The file is standard JSON. Edit with any text editor:

```bash
# Open in default editor
${EDITOR:-vi} ~/.config/aidevops/settings.json
```

### From scripts

```bash
# Source the helper
source ~/.aidevops/agents/scripts/settings-helper.sh

# Or call directly
value=$(~/.aidevops/agents/scripts/settings-helper.sh get auto_update.enabled)
```

### Reading settings in other scripts

For scripts that need to read settings, use the `settings-helper.sh get` command or read the JSON directly with `jq`:

```bash
# Via helper (respects precedence: env > file > default)
auto_update=$(~/.aidevops/agents/scripts/settings-helper.sh get auto_update.enabled)

# Direct jq read (file only, no env var precedence)
auto_update=$(jq -r '.auto_update.enabled' ~/.config/aidevops/settings.json)
```

## Migration from Environment Variables

Previously, aidevops settings were configured exclusively via `AIDEVOPS_*` environment variables. The settings.json file replaces this as the primary configuration method, but env vars continue to work as overrides.

**No action required**: Existing env var configurations continue to work. The env var always takes precedence over the file value.

**To migrate**: Remove `AIDEVOPS_*` exports from your shell config and set the equivalent values in settings.json instead. This gives you a single, documented configuration file.

| Old (env var) | New (settings.json key) |
|---------------|------------------------|
| `AIDEVOPS_AUTO_UPDATE=false` | `auto_update.enabled = false` |
| `AIDEVOPS_UPDATE_INTERVAL=30` | `auto_update.interval_minutes = 30` |
| `AIDEVOPS_SKILL_AUTO_UPDATE=false` | `auto_update.skill_auto_update = false` |
| `AIDEVOPS_TOOL_AUTO_UPDATE=false` | `auto_update.tool_auto_update = false` |
| `AIDEVOPS_SUPERVISOR_PULSE=false` | `supervisor.pulse_enabled = false` |
| `AIDEVOPS_REPO_SYNC=false` | `repo_sync.enabled = false` |

## Peak Hours Configuration

Anthropic tightens session limits during weekday peak hours (5 AM–11 AM PT). Enable the peak-hours cap to automatically reduce `MAX_WORKERS` during this window:

```bash
# Enable peak-hours cap (disabled by default)
settings-helper.sh set supervisor.peak_hours_enabled true

# Customise the window (default: 5→11 local time)
settings-helper.sh set supervisor.peak_hours_start 5
settings-helper.sh set supervisor.peak_hours_end 11

# Set the fraction (default: 0.2 = 20% of off-peak MAX_WORKERS, rounded up, min 1)
settings-helper.sh set supervisor.peak_hours_worker_fraction 0.2
```

**How it works**: `calculate_max_workers()` in `pulse-wrapper.sh` computes the RAM-based worker count first, then calls `apply_peak_hours_cap()`. If the current local hour falls within `[peak_hours_start, peak_hours_end)`, the result is capped at `ceil(off_peak_max × peak_hours_worker_fraction)`, minimum 1. The cap is applied after the RAM-based clamp so it can only reduce, never increase, the worker count.

**Timezone**: The pulse uses `date +%H` (system local time). Set your system timezone to match the desired window timezone. The `peak_hours_tz` field is documentation-only.

**Overnight windows**: Set `peak_hours_start > peak_hours_end` for overnight windows (e.g., `start=22, end=6` covers 10 PM–6 AM).
