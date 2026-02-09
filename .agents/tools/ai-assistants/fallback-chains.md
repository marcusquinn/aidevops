---
description: Fallback chain configuration for multi-provider model resolution
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
---

# Fallback Chain Configuration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `scripts/fallback-chain-helper.sh [resolve|trigger|chain|status|validate|gateway]`
- **Config**: `configs/fallback-chain-config.json` (from `.json.txt` template)
- **Per-agent**: YAML frontmatter `fallback-chain:` in model tier files
- **Database**: `~/.aidevops/.agent-workspace/fallback-chain.db`
- **Triggers**: api_error, timeout, rate_limit, auth_error, overloaded
- **Gateways**: OpenRouter, Cloudflare AI Gateway

<!-- AI-CONTEXT-END -->

## Overview

The fallback chain system provides configurable, multi-provider model resolution with automatic failover. When a provider fails (API error, timeout, rate limit), the system walks a chain of alternative providers until one succeeds.

```text
Request -> Primary Provider -> [FAIL] -> Fallback 1 -> [FAIL] -> Gateway Provider -> [OK]
                                  |                        |
                              cooldown                 cooldown
```

## Configuration Layers

Fallback chains are resolved with this priority:

1. **Per-agent frontmatter** -- `fallback-chain:` in model tier `.md` files
2. **Global config** -- `configs/fallback-chain-config.json` tier-specific chains
3. **Global default** -- `configs/fallback-chain-config.json` `default` chain
4. **Hardcoded** -- Built-in minimal chains matching `model-availability-helper.sh`

### Per-Agent Frontmatter

Add `fallback-chain:` to any model tier file's YAML frontmatter:

```yaml
---
model: anthropic/claude-sonnet-4-20250514
model-tier: sonnet
model-fallback: openai/gpt-4.1
fallback-chain:
  - anthropic/claude-sonnet-4-20250514
  - openai/gpt-4.1
  - google/gemini-2.5-pro
  - openrouter/anthropic/claude-sonnet-4-20250514
---
```

### Global Config

Edit `configs/fallback-chain-config.json` (copy from `.json.txt` template):

```json
{
  "chains": {
    "sonnet": [
      "anthropic/claude-sonnet-4-20250514",
      "openai/gpt-4.1",
      "google/gemini-2.5-pro",
      "openrouter/anthropic/claude-sonnet-4-20250514"
    ]
  }
}
```

## Model Spec Formats

| Format | Example | Description |
|--------|---------|-------------|
| `provider/model` | `anthropic/claude-sonnet-4-20250514` | Direct provider API |
| `openrouter/provider/model` | `openrouter/anthropic/claude-sonnet-4-20250514` | Via OpenRouter gateway |
| `gateway/cf/provider/model` | `gateway/cf/anthropic/claude-sonnet-4-20250514` | Via Cloudflare AI Gateway |

## Trigger Types

Triggers activate fallback when specific error conditions are detected:

| Trigger | HTTP Codes | Default Cooldown | Description |
|---------|-----------|-----------------|-------------|
| `api_error` | 500, 502, 503, 504 | 5 minutes | Server errors, connection failures |
| `timeout` | -- | 3 minutes | Request exceeded timeout |
| `rate_limit` | 429 | 1 minute | Rate limited by provider |
| `auth_error` | 401, 403 | 1 hour | Invalid or expired API key |
| `overloaded` | 529 | 2 minutes | Provider capacity exceeded |

Triggers can be enabled/disabled and cooldowns customized in the config:

```json
{
  "triggers": {
    "rate_limit": {
      "enabled": true,
      "cooldown_seconds": 60
    },
    "auth_error": {
      "enabled": true,
      "cooldown_seconds": 3600
    }
  }
}
```

## Gateway Providers

Gateway providers route requests through a unified API, providing provider-level fallback without needing individual API keys for every provider.

### OpenRouter

OpenRouter provides access to 100+ models through a single API key.

```bash
# Check OpenRouter availability
fallback-chain-helper.sh gateway openrouter

# Models routed via OpenRouter use the format:
# openrouter/provider/model
# e.g., openrouter/anthropic/claude-sonnet-4-20250514
```

**Setup**: Set `OPENROUTER_API_KEY` environment variable or store via `aidevops secret set OPENROUTER_API_KEY`.

### Cloudflare AI Gateway

Cloudflare AI Gateway adds caching, rate limiting, and analytics on top of any provider.

```bash
# Check Cloudflare AI Gateway availability
fallback-chain-helper.sh gateway cloudflare

# Models routed via CF AI Gateway use the format:
# gateway/cf/provider/model
# e.g., gateway/cf/anthropic/claude-sonnet-4-20250514
```

**Setup**: Configure `account_id` and `gateway_id` in `configs/fallback-chain-config.json`. Set `CF_AIG_TOKEN` for authenticated gateways.

## CLI Usage

```bash
# Resolve best model for a tier (walks the chain)
fallback-chain-helper.sh resolve coding
fallback-chain-helper.sh resolve sonnet --json

# Resolve with per-agent override
fallback-chain-helper.sh resolve sonnet --agent models/sonnet.md

# Process an error trigger (puts failed provider in cooldown, returns next)
fallback-chain-helper.sh trigger coding 429 --failed-model anthropic/claude-opus-4-6

# Show chain for a tier
fallback-chain-helper.sh chain opus

# Show overall status (cooldowns, gateways, recent triggers)
fallback-chain-helper.sh status

# Validate configuration
fallback-chain-helper.sh validate

# Check gateway health
fallback-chain-helper.sh gateway openrouter
fallback-chain-helper.sh gateway cloudflare
```

## Integration

### Supervisor (automatic)

The supervisor's `resolve_model()` function automatically uses the fallback chain:

```text
resolve_model("coding")
  -> fallback-chain-helper.sh resolve coding    (t132.4: full chain)
  -> model-availability-helper.sh resolve coding (t132.3: primary/fallback)
  -> static defaults                             (hardcoded last resort)
```

### Model Availability Helper

The `resolve` command now falls through to the fallback chain when primary/fallback both fail:

```bash
# Simple resolution (primary + single fallback)
model-availability-helper.sh resolve coding

# Full chain resolution (all configured providers + gateways)
model-availability-helper.sh resolve-chain coding
model-availability-helper.sh resolve-chain sonnet --agent models/sonnet.md
```

### Error Recovery in Workers

Workers can use the trigger command to handle runtime errors:

```bash
# Worker encounters rate limit from Anthropic
NEXT_MODEL=$(fallback-chain-helper.sh trigger coding 429 \
  --failed-model anthropic/claude-opus-4-6 --quiet)

# Re-dispatch with the fallback model
opencode run -m "$NEXT_MODEL" "Continue the task..."
```

## Architecture

```text
                    ┌─────────────────────────────────────┐
                    │        Fallback Chain Config          │
                    │  (per-agent frontmatter > global)     │
                    └──────────────┬──────────────────────┘
                                   │
                    ┌──────────────▼──────────────────────┐
                    │     fallback-chain-helper.sh          │
                    │  ┌─────────────────────────────────┐ │
                    │  │ Trigger Detection                │ │
                    │  │ (429, 5xx, timeout, auth, 529)   │ │
                    │  └──────────┬──────────────────────┘ │
                    │             │                         │
                    │  ┌──────────▼──────────────────────┐ │
                    │  │ Provider Cooldown Manager        │ │
                    │  │ (SQLite, per-provider TTL)       │ │
                    │  └──────────┬──────────────────────┘ │
                    │             │                         │
                    │  ┌──────────▼──────────────────────┐ │
                    │  │ Chain Walker                     │ │
                    │  │ (skip cooled-down providers)     │ │
                    │  └──────────┬──────────────────────┘ │
                    └─────────────┼───────────────────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                   │
     ┌────────▼──────┐  ┌────────▼──────┐  ┌────────▼──────┐
     │ Direct Provider│  │  OpenRouter   │  │  CF AI Gateway │
     │ (Anthropic,    │  │  (unified API)│  │  (cache+route) │
     │  OpenAI, etc.) │  │              │  │               │
     └───────────────┘  └──────────────┘  └───────────────┘
```

## Related

- `scripts/model-availability-helper.sh` -- Provider health probes and tier resolution
- `scripts/model-registry-helper.sh` -- Model registry with periodic sync
- `scripts/supervisor-helper.sh` -- Autonomous task orchestration
- `tools/ai-assistants/models/README.md` -- Model tier definitions
- `services/hosting/cloudflare-platform/references/ai-gateway/README.md` -- CF AI Gateway reference
