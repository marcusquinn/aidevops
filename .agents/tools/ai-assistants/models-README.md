# Model-Specific Subagents

Model-specific subagents are the model-routing mechanism. Instead of passing a model to Task directly, the orchestrator selects a subagent whose frontmatter declares the concrete provider/model.

## Core Rules

- **In-session Task calls use the session model.** A prompt can request another model, but the runtime does not switch models mid-session.
- **True cross-model routing requires headless dispatch.** Supervisor/runner helpers read the selected subagent frontmatter and pass the resolved model ID to the CLI.
- **Tier names are the stable interface.** Callers should target `haiku`, `sonnet`, `pro`, `opus`, etc.; the concrete model can change behind that alias.

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

### In-session Task tool

```text
Task(subagent_type="general", prompt="Review this code using gemini-2.5-pro...")
```

The prompt can describe the desired model, but the Task tool still runs on the current session model.

### Headless dispatch

```bash
# Runner reads model from subagent frontmatter
Claude -m "gemini-2.5-pro" -p "Review this codebase..."
```

Supervisor flow:

1. Task metadata specifies a tier such as `model: pro`
2. The supervisor reads `models/pro.md` frontmatter
3. The runner receives `--model` with the resolved provider/model ID

## Fallback Chains (t132.4)

Each tier can define a longer fallback chain than the simple primary/fallback pair. On provider failure (API error, timeout, rate limit), resolution walks the chain until it finds a healthy provider, including gateways such as OpenRouter and Cloudflare AI Gateway.

```yaml
fallback-chain:
  - anthropic/claude-sonnet-4-6
  - openai/gpt-5.3-codex
  - google/gemini-2.5-pro
  - openrouter/anthropic/claude-sonnet-4-6
```

- Per-tier override: add `fallback-chain:` to the model subagent frontmatter
- Global defaults: `configs/fallback-chain-config.json`
- Full docs: `tools/ai-assistants/fallback-chains.md`

## Adding or Updating a Tier

1. Create or edit the model subagent in `models/`
2. Set `model:` to the provider/model ID
3. Optionally add `fallback-chain:`
4. Update the tier mapping in `tools/context/model-routing.md`
5. Update `compare-models-helper.sh` `MODEL_DATA` if pricing/capability tracking applies
6. Run `model-registry-helper.sh sync --force`
7. Run `model-registry-helper.sh check`

## Model Registry

`model-registry-helper.sh` maintains `~/.aidevops/.agent-workspace/model-registry.db` from three sources:

1. Subagent frontmatter in `models/*.md`
2. Embedded pricing/capability data in `compare-models-helper.sh`
3. Provider APIs for live model discovery

```bash
model-registry-helper.sh sync          # Sync from all sources
model-registry-helper.sh status        # Registry health and tier mapping
model-registry-helper.sh check         # Verify subagent models exist
model-registry-helper.sh suggest       # New models worth adding
model-registry-helper.sh deprecations  # Deprecated/unavailable models
model-registry-helper.sh diff          # Registry vs local config
```

The registry syncs automatically on `aidevops update` and can also run on a schedule.

## Related

- `tools/ai-assistants/fallback-chains.md` — fallback configuration and gateway providers
- `tools/context/model-routing.md` — cost-aware routing rules
- `scripts/compare-models-helper.sh discover --probe` — provider discovery
- `model-registry-helper.sh` — registry maintenance and health checks
- `fallback-chain-helper.sh` — fallback resolution and trigger detection
- `tools/ai-assistants/headless-dispatch.md` — CLI dispatch with model selection
