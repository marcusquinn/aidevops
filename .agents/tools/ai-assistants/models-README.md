# Model-Specific Subagents

Orchestrator selects subagents based on frontmatter `model` declaration for cross-provider routing.

## Core Rules

- **In-session Task calls use the session model.** Runtimes do not switch models mid-session.
- **Cross-model routing requires headless dispatch.** Supervisor reads subagent frontmatter and passes resolved model ID to CLI.
- **Tier names are the stable interface.** Target `haiku`, `sonnet`, `pro`, `opus`, etc.; concrete models change behind these aliases.

## Tier Mapping

| Tier | Subagent | Primary Model | Fallback |
|------|----------|---------------|----------|
| `haiku` | `models/haiku.md` | claude-haiku-4-5-20251001 | gemini-2.5-flash-preview-05-20 |
| `flash` | `models/flash.md` | gemini-2.5-flash-preview-05-20 | gpt-4.1-mini |
| `sonnet` | `models/sonnet.md` | claude-sonnet-4-6 | gpt-5.3-codex |
| `composer2` | `models/composer2.md` | cursor/composer-2 | claude-sonnet-4-6 |
| `pro` | `models/pro.md` | gemini-2.5-pro | claude-sonnet-4-6 |
| `opus` | `models/opus.md` | claude-opus-4-6 | gpt-5.4 |

## Resolution Flow

**In-session:** `Task(subagent_type="general", ...)` — prompt model requests ignored; runs on session model.

**Headless:** `Claude -m "gemini-2.5-pro" -p "..."` — task metadata specifies tier → supervisor reads `models/<tier>.md` frontmatter → runner receives `--model` with resolved ID.

## Fallback Chains (t132.4)

Tiers define fallback chains for provider failures (API error, timeout, rate limit). Resolution walks the chain until a healthy provider is found.

```yaml
fallback-chain:
  - anthropic/claude-sonnet-4-6
  - openai/gpt-5.3-codex
  - google/gemini-2.5-pro
  - openrouter/anthropic/claude-sonnet-4-6
```

- **Per-tier override:** Add `fallback-chain:` to model subagent frontmatter.
- **Global defaults:** `configs/fallback-chain-config.json`.
- **Docs:** `tools/ai-assistants/fallback-chains.md`.

## Adding or Updating a Tier

1. Edit/create model subagent in `models/`.
2. Set `model:` to provider/model ID.
3. Update mapping in `tools/context/model-routing.md`.
4. Update `compare-models-helper.sh` `MODEL_DATA` if applicable.
5. Run `model-registry-helper.sh sync --force && model-registry-helper.sh check`.

## Model Registry

`model-registry-helper.sh` maintains `~/.aidevops/.agent-workspace/model-registry.db`. Syncs on `aidevops update`.

```bash
model-registry-helper.sh sync          # Sync all sources
model-registry-helper.sh status        # Health and tier mapping
model-registry-helper.sh check         # Verify models exist
model-registry-helper.sh suggest       # New model suggestions
model-registry-helper.sh deprecations  # Unavailable models
model-registry-helper.sh diff          # Registry vs local config
```

## Related

- `tools/ai-assistants/fallback-chains.md` — fallback config
- `tools/context/model-routing.md` — cost-aware routing
- `scripts/compare-models-helper.sh discover --probe` — discovery
- `model-registry-helper.sh` — maintenance
- `fallback-chain-helper.sh` — resolution
- `tools/ai-assistants/headless-dispatch.md` — CLI dispatch
