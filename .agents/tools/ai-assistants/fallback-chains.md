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

Data-driven routing table (JSON) that AI reads directly. The bash script only checks availability — all routing decisions (which model to try, when to fall back, error recovery) are made by the AI agent, not bash. Follows the **Intelligence Over Scripts** principle.

## Routing Table

`configs/model-routing-table.json` defines models per tier:

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
fallback-chain-helper.sh resolve coding
fallback-chain-helper.sh resolve sonnet --json --quiet
fallback-chain-helper.sh table
fallback-chain-helper.sh help
```

## How Resolution Works

1. Read routing table for the requested tier
2. Walk model list in order
3. Check each model via `model-availability-helper.sh`
4. Return first available model; exit code 1 if all exhausted

No cooldowns, triggers, gateway probing, or SQLite database.

## Integration

### Callers

| Caller | Function | How it calls |
|--------|----------|-------------|
| `model-availability-helper.sh` | `resolve_tier()` | `fallback-chain-helper.sh resolve <tier> --quiet` as extended fallback |
| `model-availability-helper.sh` | `resolve_tier_chain()` | `fallback-chain-helper.sh resolve <tier> --quiet` for full chain |
| `shared-constants.sh` | `resolve_model_tier()` | `fallback-chain-helper.sh resolve <tier> --quiet` with static fallback |

### AI Agent Usage

AI agents read `model-routing.md` for routing rules and the routing table for available models. Runtime failures → AI decides next action (retry, fall back, escalate).

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
