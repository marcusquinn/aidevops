# Configuration Reference

aidevops uses two complementary configuration files. This document covers both systems, every available option, and how they interact.

## Configuration Files

| File | Format | Purpose | Managed by |
|------|--------|---------|------------|
| `~/.config/aidevops/config.jsonc` | JSONC | Framework behaviour: updates, models, safety, quality, orchestration, paths | `config-helper.sh` / `aidevops config` |
| `~/.config/aidevops/settings.json` | JSON | User preferences: onboarding state, UI, model routing defaults | `settings-helper.sh` |

Both files are created automatically on first run (`setup.sh` or the respective helper's `init` command). Neither file is required -- sensible defaults apply when a file or key is absent.

### Why two files?

`settings.json` was introduced first (t1379) as a lightweight key-value store for onboarding and UI preferences. `config.jsonc` was added later (t2730) as a namespaced, schema-validated system covering the full framework. The two coexist: `settings.json` handles user-facing preferences while `config.jsonc` handles framework internals. Over time, `config.jsonc` is the primary configuration surface.

## Precedence (highest wins)

Both systems follow the same precedence order:

1. **Environment variable** (`AIDEVOPS_*`) -- always wins
2. **User config file** -- persistent overrides
3. **Built-in defaults** -- hardcoded in the helper script or defaults file

This means you can override any setting temporarily via an environment variable without editing a file. Useful for CI/CD, testing, or one-off runs.

For `config.jsonc` specifically, the defaults file is:

```text
~/.aidevops/agents/configs/aidevops.defaults.jsonc
```

**Do not edit the defaults file** -- it is overwritten on every `aidevops update`. Place your overrides in `~/.config/aidevops/config.jsonc`.

## Quick Start

```bash
# View all config with current values
aidevops config list

# Get a single value
aidevops config get updates.auto_update

# Set a value
aidevops config set updates.auto_update false

# Reset a key to its default
aidevops config reset updates.auto_update

# Reset all config to defaults
aidevops config reset

# Validate your config against the schema
aidevops config validate

# Show config file paths
aidevops config path

# Migrate from legacy feature-toggles.conf (automatic on first use)
aidevops config migrate
```

For `settings.json`:

```bash
# Create settings file with defaults
settings-helper.sh init

# Get/set values (dot-notation)
settings-helper.sh get auto_update.enabled
settings-helper.sh set auto_update.enabled false

# List all settings
settings-helper.sh list

# Export as shell env vars
eval "$(settings-helper.sh export-env)"
```

---

## config.jsonc -- Full Reference

The JSONC config file supports `//` line comments, `/* block comments */`, and trailing commas. A JSON Schema is available for editor autocomplete:

```jsonc
{
  "$schema": "~/.aidevops/agents/configs/aidevops-config.schema.json",
  // your overrides here
}
```

### updates

Auto-update behaviour for aidevops, skills, tools, and OpenClaw.

| Key | Type | Default | Env Override | Description |
|-----|------|---------|-------------|-------------|
| `updates.auto_update` | boolean | `true` | `AIDEVOPS_AUTO_UPDATE` | Master switch for automatic update checks. Set `false` to disable all automatic updates. Manual update: `aidevops update`. |
| `updates.update_interval_minutes` | integer | `10` | `AIDEVOPS_UPDATE_INTERVAL` | Minutes between update checks. Minimum: 1. |
| `updates.skill_auto_update` | boolean | `true` | `AIDEVOPS_SKILL_AUTO_UPDATE` | Check imported skills for upstream changes. Skills are agent packages imported via `aidevops skill add`. |
| `updates.skill_freshness_hours` | integer | `24` | `AIDEVOPS_SKILL_FRESHNESS_HOURS` | Hours between skill freshness checks. Minimum: 1. |
| `updates.tool_auto_update` | boolean | `true` | `AIDEVOPS_TOOL_AUTO_UPDATE` | Update installed tools (npm, brew, pip) when user is idle. |
| `updates.tool_freshness_hours` | integer | `6` | `AIDEVOPS_TOOL_FRESHNESS_HOURS` | Hours between tool freshness checks. Minimum: 1. |
| `updates.tool_idle_hours` | integer | `6` | `AIDEVOPS_TOOL_IDLE_HOURS` | Required user idle hours before tool updates run. Prevents updates during active work. Minimum: 1. |
| `updates.openclaw_auto_update` | boolean | `true` | `AIDEVOPS_OPENCLAW_AUTO_UPDATE` | Check for OpenClaw updates (only if the `openclaw` CLI is installed). |
| `updates.openclaw_freshness_hours` | integer | `24` | `AIDEVOPS_OPENCLAW_FRESHNESS_HOURS` | Hours between OpenClaw update checks. Minimum: 1. |

**Example -- disable all automatic updates:**

```jsonc
{
  "updates": {
    "auto_update": false
  }
}
```

**Example -- check for updates every hour, but leave skill/tool updates on defaults:**

```jsonc
{
  "updates": {
    "update_interval_minutes": 60
  }
}
```

### integrations

Controls whether `setup.sh` manages external AI assistant configurations.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `integrations.manage_opencode_config` | boolean | `true` | Allow `setup.sh` to modify OpenCode config (agents, MCPs, settings). Set `false` if you manage `opencode.json` manually. |
| `integrations.manage_claude_config` | boolean | `true` | Allow `setup.sh` to modify Claude Code config. Set `false` if you manage Claude Code config manually. |

**Example -- manage OpenCode but not Claude Code:**

```jsonc
{
  "integrations": {
    "manage_claude_config": false
  }
}
```

### orchestration

Supervisor, dispatch, and autonomous operation settings.

| Key | Type | Default | Env Override | Description |
|-----|------|---------|-------------|-------------|
| `orchestration.supervisor_pulse` | boolean | `true` | `AIDEVOPS_SUPERVISOR_PULSE` | Enable the autonomous supervisor pulse scheduler. When enabled, dispatches workers, merges PRs, evaluates results every 2 minutes. |
| `orchestration.repo_sync` | boolean | `true` | `AIDEVOPS_REPO_SYNC` | Enable daily `git pull --ff-only` on clean repos registered in `repos.json`. |

**Example -- disable the supervisor pulse (manual dispatch only):**

```jsonc
{
  "orchestration": {
    "supervisor_pulse": false
  }
}
```

### safety

Security hooks, verification, and protective measures.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `safety.hooks_enabled` | boolean | `true` | Install git pre-commit and pre-push safety hooks that block destructive commands. Set `false` if hooks conflict with your workflow. |
| `safety.verification_enabled` | boolean | `true` | Enable parallel model verification for high-stakes operations. When `true`, destructive operations are verified by a second AI model before execution. |
| `safety.verification_tier` | string | `"haiku"` | Model tier used for verification checks. Options: `haiku`, `flash`, `sonnet`, `pro`, `opus`. Use the cheapest tier that provides sufficient reasoning. |

**Example -- disable git hooks but keep verification:**

```jsonc
{
  "safety": {
    "hooks_enabled": false
  }
}
```

### ui

User interface and session experience settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ui.session_greeting` | boolean | `true` | Show version check and update prompt when starting an AI session. Set `false` for a quieter startup. |
| `ui.shell_aliases` | boolean | `true` | Add aidevops shell aliases to `.zshrc`/`.bashrc` during setup. Set `false` if you manage your shell config manually. |
| `ui.onboarding_prompt` | boolean | `true` | Offer to launch `/onboarding` after `setup.sh` completes. Set `false` to skip the prompt. |

**Example -- quiet startup, no shell aliases:**

```jsonc
{
  "ui": {
    "session_greeting": false,
    "shell_aliases": false
  }
}
```

### models

Model routing, tiers, provider configuration, rate limits, fallback chains, and gateways.

#### models.tiers

Each tier maps to an ordered list of models. The first available model in the list is used. If all models in a tier are unavailable, the optional `fallback` tier is tried.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `models.tiers.<name>.models` | string[] | (see defaults) | Ordered list of model identifiers for this tier. |
| `models.tiers.<name>.fallback` | string | (none) | Tier name to fall back to if all models in this tier are unavailable. |

**Default tiers:**

| Tier | Models | Fallback |
|------|--------|----------|
| `local` | `local/llama.cpp` | `haiku` |
| `haiku` | `anthropic/claude-haiku-4-5` | -- |
| `flash` | `anthropic/claude-haiku-4-5` | -- |
| `sonnet` | `anthropic/claude-sonnet-4-6` | -- |
| `pro` | `anthropic/claude-sonnet-4-6` | -- |
| `opus` | `anthropic/claude-opus-4-6` | -- |
| `coding` | `anthropic/claude-opus-4-6`, `anthropic/claude-sonnet-4-6` | -- |
| `eval` | `anthropic/claude-sonnet-4-6` | -- |
| `health` | `anthropic/claude-sonnet-4-6` | -- |

**Example -- add a custom tier with OpenAI fallback:**

```jsonc
{
  "models": {
    "tiers": {
      "fast": {
        "models": ["openai/gpt-4o-mini", "anthropic/claude-haiku-4-5"],
        "fallback": "haiku"
      }
    }
  }
}
```

#### models.providers

Provider endpoint and authentication configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `models.providers.<name>.endpoint` | string (URI) | (see defaults) | API endpoint URL. |
| `models.providers.<name>.key_env` | string or null | (see defaults) | Environment variable name containing the API key. `null` for keyless providers (e.g., local). |
| `models.providers.<name>.probe_timeout_seconds` | integer | `10` | Timeout in seconds for availability probes. Minimum: 1. |

**Default providers:**

| Provider | Endpoint | Key Env |
|----------|----------|---------|
| `local` | `http://localhost:8080/v1/chat/completions` | `null` |
| `anthropic` | `https://api.anthropic.com/v1/messages` | `ANTHROPIC_API_KEY` |

**Example -- add an OpenAI provider:**

```jsonc
{
  "models": {
    "providers": {
      "openai": {
        "endpoint": "https://api.openai.com/v1/chat/completions",
        "key_env": "OPENAI_API_KEY",
        "probe_timeout_seconds": 10
      }
    }
  }
}
```

#### models.fallback_chains

Per-tier fallback chains for model-level failover. Each key is a tier name, and the value is an ordered list of model identifiers to try.

**Default chains:**

| Tier | Chain |
|------|-------|
| `haiku` | `anthropic/claude-haiku-4-5` |
| `flash` | `anthropic/claude-haiku-4-5` |
| `sonnet` | `anthropic/claude-sonnet-4-6` |
| `pro` | `anthropic/claude-sonnet-4-6` |
| `opus` | `anthropic/claude-opus-4-6` |
| `coding` | `anthropic/claude-opus-4-6`, `anthropic/claude-sonnet-4-6` |
| `eval` | `anthropic/claude-sonnet-4-6` |
| `health` | `anthropic/claude-sonnet-4-6` |
| `default` | `anthropic/claude-sonnet-4-6` |

#### models.fallback_triggers

Configure which error conditions trigger a fallback to the next model in the chain.

| Trigger | Enabled | Cooldown (seconds) | Description |
|---------|---------|---------------------|-------------|
| `api_error` | `true` | `300` | General API errors (5xx, network failures). |
| `timeout` | `true` | `180` | Request timeout exceeded. |
| `rate_limit` | `true` | `60` | Provider rate limit hit (429). |
| `auth_error` | `true` | `3600` | Authentication failure (401/403). Long cooldown -- likely needs manual fix. |
| `overloaded` | `true` | `120` | Provider overloaded (503). |

**Example -- disable fallback on rate limits (prefer waiting):**

```jsonc
{
  "models": {
    "fallback_triggers": {
      "rate_limit": { "enabled": false }
    }
  }
}
```

#### models.settings

General model routing settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `models.settings.probe_timeout_seconds` | integer | `10` | Global default timeout for provider availability probes. |
| `models.settings.cache_ttl_seconds` | integer | `300` | How long to cache provider availability results. |
| `models.settings.max_chain_depth` | integer | `5` | Maximum number of fallback hops before giving up. |
| `models.settings.default_cooldown_seconds` | integer | `300` | Default cooldown after a fallback trigger fires. |
| `models.settings.log_retention_days` | integer | `30` | Days to retain model routing logs. |

#### models.rate_limits

Rate limits per provider. Adjust these to match your API plan tier.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `models.rate_limits.warn_pct` | integer | `80` | Percentage of rate limit at which to warn. Range: 0-100. |
| `models.rate_limits.window_minutes` | integer | `1` | Rate limit window size in minutes. Minimum: 1. |
| `models.rate_limits.providers.<name>.requests_per_min` | integer | (varies) | Maximum requests per minute for this provider. |
| `models.rate_limits.providers.<name>.tokens_per_min` | integer | (varies) | Maximum tokens per minute for this provider. |

**Default rate limits:**

| Provider | Requests/min | Tokens/min |
|----------|-------------|------------|
| `anthropic` | 50 | 40,000 |
| `openai` | 500 | 200,000 |
| `google` | 60 | 1,000,000 |
| `deepseek` | 60 | 100,000 |
| `openrouter` | 200 | 500,000 |
| `groq` | 30 | 6,000 |
| `xai` | 60 | 100,000 |

**Example -- increase Anthropic limits for a higher plan tier:**

```jsonc
{
  "models": {
    "rate_limits": {
      "providers": {
        "anthropic": {
          "requests_per_min": 200,
          "tokens_per_min": 200000
        }
      }
    }
  }
}
```

#### models.gateways

Gateway provider configuration for provider-level fallback routing (e.g., OpenRouter, Cloudflare AI Gateway).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `models.gateways.<name>.enabled` | boolean | `false` | Enable this gateway. |
| `models.gateways.<name>.endpoint` | string | (varies) | Gateway API endpoint. |
| `models.gateways.<name>.key_env_var` | string | (varies) | Environment variable for the gateway API key. |
| `models.gateways.<name>.account_id` | string | `""` | Account ID (Cloudflare). |
| `models.gateways.<name>.gateway_id` | string | `""` | Gateway ID (Cloudflare). |

**Default gateways (both disabled):**

| Gateway | Endpoint | Key Env |
|---------|----------|---------|
| `openrouter` | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` |
| `cloudflare` | (constructed from account/gateway IDs) | `CF_AIG_TOKEN` |

**Example -- enable OpenRouter as a fallback gateway:**

```jsonc
{
  "models": {
    "gateways": {
      "openrouter": {
        "enabled": true
      }
    }
  }
}
```

### quality

Code quality, linting, and CI/CD timing configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `quality.sonarcloud_grade` | string | `"A"` | Target quality grade for SonarCloud analysis. Options: `A`, `B`, `C`, `D`, `E`. |
| `quality.shellcheck_max_violations` | integer | `0` | ShellCheck violation tolerance. `0` means zero tolerance. Minimum: 0. |

#### quality.ci_timing

CI/CD service timing constants (in seconds). Based on observed completion times across multiple PRs. Used by scripts that poll CI status.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `quality.ci_timing.fast_wait` | integer | `10` | Initial wait before first poll (fast services). |
| `quality.ci_timing.fast_poll` | integer | `5` | Poll interval for fast services. |
| `quality.ci_timing.medium_wait` | integer | `60` | Initial wait for medium services. |
| `quality.ci_timing.medium_poll` | integer | `15` | Poll interval for medium services. |
| `quality.ci_timing.slow_wait` | integer | `120` | Initial wait for slow services. |
| `quality.ci_timing.slow_poll` | integer | `30` | Poll interval for slow services. |
| `quality.ci_timing.fast_timeout` | integer | `60` | Timeout for fast services. |
| `quality.ci_timing.medium_timeout` | integer | `180` | Timeout for medium services. |
| `quality.ci_timing.slow_timeout` | integer | `600` | Timeout for slow services. |
| `quality.ci_timing.backoff_base` | integer | `15` | Base interval for exponential backoff. |
| `quality.ci_timing.backoff_max` | integer | `120` | Maximum backoff interval. |
| `quality.ci_timing.backoff_multiplier` | integer | `2` | Backoff multiplier per retry. |

**Example -- increase timeouts for a slow CI provider:**

```jsonc
{
  "quality": {
    "ci_timing": {
      "slow_timeout": 900,
      "slow_poll": 45
    }
  }
}
```

### verification

High-stakes operation verification triggers. This is the detailed verification policy that complements `safety.verification_enabled`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `verification.enabled` | boolean | `true` | Global verification policy switch. |
| `verification.default_gate` | string | `"warn"` | Default gate for uncategorised operations. Options: `block`, `warn`, `allow`. |
| `verification.cross_provider` | boolean | `true` | Use a different AI provider for verification (reduces correlated hallucinations). |
| `verification.verifier_tier` | string | `"sonnet"` | Model tier for the verifier. |
| `verification.escalation_tier` | string | `"opus"` | Model tier for escalation when verifier is uncertain. |

#### verification.categories

Per-category risk levels and gates. Each category maps to a risk level and a gate action.

| Category | Risk Level | Gate | Description |
|----------|-----------|------|-------------|
| `git_destructive` | `critical` | `block` | `git push --force`, `git reset --hard`, branch deletion on main. |
| `production_deploy` | `critical` | `block` | Deploying to production environments. |
| `data_migration` | `high` | `warn` | Database migrations, bulk data changes. |
| `security_sensitive` | `high` | `warn` | Credential changes, permission modifications. |
| `financial` | `high` | `warn` | Payment processing, invoice generation. |
| `infrastructure_destruction` | `critical` | `block` | `DROP DATABASE`, server deletion, DNS zone removal. |

Gate actions:

- **`block`** -- Operation is prevented unless the second model agrees it is safe.
- **`warn`** -- Operation proceeds with a logged warning. Verification is recommended but not enforced.
- **`allow`** -- No verification. Operation proceeds normally.

**Example -- downgrade data migration to allow (you trust your migration scripts):**

```jsonc
{
  "verification": {
    "categories": {
      "data_migration": { "risk_level": "medium", "gate": "allow" }
    }
  }
}
```

### paths

Directory and file path configuration. Supports `~` for the home directory.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `paths.agents_dir` | string | `~/.aidevops/agents` | Base installation directory for aidevops agents. |
| `paths.config_dir` | string | `~/.config/aidevops` | User configuration directory. |
| `paths.workspace_dir` | string | `~/.aidevops/.agent-workspace` | Workspace directory for agent operations (work files, temp, mail, memory). |
| `paths.log_dir` | string | `~/.aidevops/logs` | Log directory. |
| `paths.memory_db` | string | `~/.aidevops/.agent-workspace/memory/memory.db` | SQLite memory database location (cross-session memory). |
| `paths.worktree_registry_db` | string | `~/.aidevops/.agent-workspace/worktree-registry.db` | Worktree registry database. |

**Example -- move logs to a custom location:**

```jsonc
{
  "paths": {
    "log_dir": "~/logs/aidevops"
  }
}
```

---

## settings.json -- Full Reference

`settings.json` is standard JSON (no comments). It is the canonical file for user preferences and onboarding state.

**File location:** `~/.config/aidevops/settings.json`

**Helper script:** `~/.aidevops/agents/scripts/settings-helper.sh`

### auto_update

Controls automatic update behaviour. Mirrors the `updates` namespace in `config.jsonc` -- if both are set, `config.jsonc` takes precedence for framework scripts, while `settings.json` is used by `settings-helper.sh` consumers.

| Key | Type | Default | Env Override | Description |
|-----|------|---------|-------------|-------------|
| `auto_update.enabled` | boolean | `true` | `AIDEVOPS_AUTO_UPDATE` | Master switch for auto-update. |
| `auto_update.interval_minutes` | number | `10` | `AIDEVOPS_UPDATE_INTERVAL` | Minutes between update checks. Range: 1-1440. |
| `auto_update.skill_auto_update` | boolean | `true` | `AIDEVOPS_SKILL_AUTO_UPDATE` | Enable skill freshness checks. |
| `auto_update.skill_freshness_hours` | number | `24` | `AIDEVOPS_SKILL_FRESHNESS_HOURS` | Hours between skill checks. |
| `auto_update.tool_auto_update` | boolean | `true` | `AIDEVOPS_TOOL_AUTO_UPDATE` | Enable tool updates when idle. |
| `auto_update.tool_freshness_hours` | number | `6` | `AIDEVOPS_TOOL_FRESHNESS_HOURS` | Hours between tool checks. |
| `auto_update.tool_idle_hours` | number | `6` | `AIDEVOPS_TOOL_IDLE_HOURS` | Required idle hours before tool updates. |
| `auto_update.openclaw_auto_update` | boolean | `true` | `AIDEVOPS_OPENCLAW_AUTO_UPDATE` | Enable OpenClaw update checks. |
| `auto_update.openclaw_freshness_hours` | number | `24` | `AIDEVOPS_OPENCLAW_FRESHNESS_HOURS` | Hours between OpenClaw checks. |

### supervisor

Controls the autonomous orchestration supervisor.

| Key | Type | Default | Env Override | Description |
|-----|------|---------|-------------|-------------|
| `supervisor.pulse_enabled` | boolean | `true` | `AIDEVOPS_SUPERVISOR_PULSE` | Enable the supervisor pulse scheduler. |
| `supervisor.pulse_interval_seconds` | number | `120` | -- | Seconds between pulse cycles. Range: 30-3600. |
| `supervisor.stale_threshold_seconds` | number | `1800` | -- | Seconds before a worker is considered stale/stuck. |
| `supervisor.circuit_breaker_max_failures` | number | `3` | -- | Consecutive failures before the circuit breaker pauses dispatch. |
| `supervisor.strategic_review_hours` | number | `4` | -- | Hours between opus-tier strategic reviews of queue health. |

### repo_sync

Controls daily git repository synchronisation.

| Key | Type | Default | Env Override | Description |
|-----|------|---------|-------------|-------------|
| `repo_sync.enabled` | boolean | `true` | `AIDEVOPS_REPO_SYNC` | Enable daily `git pull --ff-only` on clean repos. |
| `repo_sync.schedule` | string | `"daily"` | -- | Sync schedule. Currently only `daily` is supported. |

### quality

Controls code quality tools and linting behaviour.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `quality.shellcheck_enabled` | boolean | `true` | Run ShellCheck on shell scripts. |
| `quality.sonarcloud_enabled` | boolean | `true` | Run SonarCloud analysis. |
| `quality.write_time_linting` | boolean | `true` | Lint files immediately after each edit (not just at commit time). |

### model_routing

Controls AI model selection and cost management.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `model_routing.default_tier` | string | `"sonnet"` | Default model tier for tasks without an explicit tier. Options: `haiku`, `sonnet`, `opus`, `flash`, `pro`. |
| `model_routing.budget_tracking_enabled` | boolean | `true` | Track per-provider API spend. |
| `model_routing.prefer_subscription` | boolean | `true` | Prefer subscription plans over API billing when both are available. |

### onboarding

Tracks onboarding state. Written by `/onboarding`, readable by scripts.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `onboarding.completed` | boolean | `false` | Whether the user has completed `/onboarding`. |
| `onboarding.work_type` | string | `""` | User's primary work type (e.g., `"web"`, `"devops"`, `"seo"`, `"WordPress"`). |
| `onboarding.familiarity` | array | `[]` | Concepts the user is familiar with (e.g., `["git", "terminal", "api_keys"]`). |

### ui

Controls terminal output behaviour.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ui.color_output` | boolean | `true` | Enable coloured terminal output. |
| `ui.verbose` | boolean | `false` | Enable verbose/debug output in scripts. |

---

## Migration from Environment Variables

Previously, aidevops settings were configured exclusively via `AIDEVOPS_*` environment variables. Both config files replace this as the primary configuration method, but env vars continue to work as the highest-priority override.

**No action required:** Existing env var configurations continue to work.

**To migrate:** Remove `AIDEVOPS_*` exports from your shell config and set the equivalent values in `config.jsonc` or `settings.json` instead.

| Old (env var) | config.jsonc key | settings.json key |
|---------------|-----------------|-------------------|
| `AIDEVOPS_AUTO_UPDATE=false` | `updates.auto_update` | `auto_update.enabled` |
| `AIDEVOPS_UPDATE_INTERVAL=30` | `updates.update_interval_minutes` | `auto_update.interval_minutes` |
| `AIDEVOPS_SKILL_AUTO_UPDATE=false` | `updates.skill_auto_update` | `auto_update.skill_auto_update` |
| `AIDEVOPS_TOOL_AUTO_UPDATE=false` | `updates.tool_auto_update` | `auto_update.tool_auto_update` |
| `AIDEVOPS_SUPERVISOR_PULSE=false` | `orchestration.supervisor_pulse` | `supervisor.pulse_enabled` |
| `AIDEVOPS_REPO_SYNC=false` | `orchestration.repo_sync` | `repo_sync.enabled` |

## Migration from feature-toggles.conf

The legacy `~/.config/aidevops/feature-toggles.conf` file is automatically migrated to `config.jsonc` on first use. After migration, the old file is preserved but no longer read. To trigger migration manually:

```bash
aidevops config migrate
```

## Service Configuration Templates

Service-specific credentials (Hostinger, Hetzner, GitHub, etc.) use a separate template system in the `configs/` directory. These are **not** part of the JSONC config -- they follow a different pattern:

1. **Templates** (`configs/[service]-config.json.txt`) -- safe to commit, contain placeholders
2. **Working files** (`configs/[service]-config.json`) -- gitignored, contain actual credentials

```bash
# Copy template to working file
cp ~/Git/aidevops/configs/hostinger-config.json.txt ~/Git/aidevops/configs/hostinger-config.json

# Edit with actual credentials
${EDITOR:-vi} ~/Git/aidevops/configs/hostinger-config.json

# Secure permissions
chmod 600 ~/Git/aidevops/configs/*-config.json
```

See [the full service configuration reference](../.agents/aidevops/configs.md).

## Schema Validation

The JSONC config has a JSON Schema at `~/.aidevops/agents/configs/aidevops-config.schema.json`. Use it for:

**Editor autocomplete** -- Add `"$schema"` to your config file:

```jsonc
{
  "$schema": "~/.aidevops/agents/configs/aidevops-config.schema.json"
}
```

**CLI validation:**

```bash
aidevops config validate
```

**Programmatic access from scripts:**

```bash
# Source the helper (respects precedence: env > user config > defaults)
source ~/.aidevops/agents/scripts/config-helper.sh
value=$(_jsonc_get "updates.auto_update")

# Or call directly
value=$(~/.aidevops/agents/scripts/config-helper.sh get updates.auto_update)
```

## Complete Example

A fully customised `~/.config/aidevops/config.jsonc`:

```jsonc
{
  "$schema": "~/.aidevops/agents/configs/aidevops-config.schema.json",

  // Check for updates hourly instead of every 10 minutes
  "updates": {
    "update_interval_minutes": 60,
    "tool_auto_update": false  // I manage tool updates manually
  },

  // Disable supervisor -- I dispatch workers manually
  "orchestration": {
    "supervisor_pulse": false
  },

  // Use opus for verification (I want the strongest reasoning)
  "safety": {
    "verification_tier": "opus"
  },

  // Quiet startup
  "ui": {
    "session_greeting": false
  },

  // Add OpenRouter as a gateway for model diversity
  "models": {
    "gateways": {
      "openrouter": {
        "enabled": true
      }
    },
    "rate_limits": {
      "providers": {
        "anthropic": {
          "requests_per_min": 200,
          "tokens_per_min": 200000
        }
      }
    }
  }
}
```
