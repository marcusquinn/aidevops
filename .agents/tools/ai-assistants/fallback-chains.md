---
description: Model routing table and availability checking for fallback resolution
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
---

# Model Routing & Fallback

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `scripts/fallback-chain-helper.sh [resolve|table|help]`
- **Routing table**: `configs/model-routing-table.json`
- **Availability**: `scripts/model-availability-helper.sh` (provider health probes)
- **Routing rules**: `tools/context/model-routing.md` (AI reads this for decisions)

<!-- AI-CONTEXT-END -->

## Overview

The fallback system uses a **data-driven routing table** (JSON) that AI reads directly to understand available models per tier. The bash script only checks model availability — all routing decisions (which model to try, when to fall back, cooldown logic) are made by the AI agent.

This follows the **Intelligence Over Scripts** principle: deterministic utilities (health checks) stay in bash; judgment calls (routing priority, error recovery) belong to the AI.

## Routing Table

The routing table at `configs/model-routing-table.json` defines models per tier:

```json
{
  "tiers": {
    "haiku":  { "models": ["anthropic/claude-haiku-4-5"] },
    "sonnet": { "models": ["anthropic/claude-sonnet-4-6"] },
    "opus":   { "models": ["anthropic/claude-opus-4-6"] },
    "coding": { "models": ["anthropic/claude-opus-4-6", "anthropic/claude-sonnet-4-6"] }
  }
}
```

Tiers: `haiku`, `flash`, `sonnet`, `pro`, `opus`, `coding`, `eval`, `health`

## CLI Usage

```bash
# Resolve best available model for a tier
fallback-chain-helper.sh resolve coding
fallback-chain-helper.sh resolve sonnet --json --quiet

# Print the full routing table
fallback-chain-helper.sh table

# Help
fallback-chain-helper.sh help
```

## How Resolution Works

1. Script reads the routing table for the requested tier
2. Walks the model list in order
3. For each model, checks provider availability via `model-availability-helper.sh`
4. Returns the first available model
5. If all models exhausted, returns exit code 1

No cooldowns, triggers, gateway probing, or SQLite database. The AI handles error recovery and routing decisions using the routing table as reference data.

## Integration

### Callers

| Caller | Function | How it calls |
|--------|----------|-------------|
| `model-availability-helper.sh` | `resolve_tier()` | `fallback-chain-helper.sh resolve <tier> --quiet` as extended fallback |
| `model-availability-helper.sh` | `resolve_tier_chain()` | `fallback-chain-helper.sh resolve <tier> --quiet` for full chain |
| `shared-constants.sh` | `resolve_model_tier()` | `fallback-chain-helper.sh resolve <tier> --quiet` with static fallback |

### AI Agent Usage

AI agents read `model-routing.md` for routing rules and the routing table for available models. When a provider fails at runtime, the AI decides the next action (retry, fall back, escalate) — not bash.

## Migration from v1

v2 removed (moved to AI judgment):
- SQLite database (cooldowns, trigger logs, gateway health)
- Provider cooldown management
- Trigger classification (429, 5xx, timeout detection)
- Gateway probing (OpenRouter, Cloudflare AI Gateway)
- Per-agent YAML frontmatter parsing
- `chain`, `status`, `validate`, `gateway`, `trigger` commands

v2 kept:
- `resolve <tier>` command (table lookup + availability check)
- `is_model_available()` health check (delegates to model-availability-helper.sh)
- Same exit codes and stdout interface

## Related

- `tools/context/model-routing.md` — Routing rules and tier definitions (AI reads this)
- `scripts/model-availability-helper.sh` — Provider health probes and tier resolution
- `scripts/model-registry-helper.sh` — Model registry with periodic sync
- `configs/model-routing-table.json` — The routing table data
