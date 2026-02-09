# Model-Specific Subagents

Model-specific subagents enable cross-provider model routing. Instead of passing a model parameter to the Task tool (which most AI tools don't support), the orchestrating agent selects a model by invoking the corresponding subagent.

## Tier Mapping

| Tier | Subagent | Primary Model | Fallback |
|------|----------|---------------|----------|
| `haiku` | `models/haiku.md` | claude-3-5-haiku | gemini-2.5-flash |
| `flash` | `models/flash.md` | gemini-2.5-flash | gpt-4.1-mini |
| `sonnet` | `models/sonnet.md` | claude-sonnet-4 | gpt-4.1 |
| `pro` | `models/pro.md` | gemini-2.5-pro | claude-sonnet-4 |
| `opus` | `models/opus.md` | claude-opus-4 | o3 |

## How It Works

### In-Session (Task Tool)

The Task tool uses `subagent_type` to select an agent. Model-specific subagents are invoked by name:

```text
Task(subagent_type="general", prompt="Review this code using gemini-2.5-pro...")
```

The Task tool in Claude Code always uses the session model. For true cross-model dispatch, use headless dispatch.

### Headless Dispatch (CLI)

The supervisor and runner helpers use model subagents to determine which CLI model flag to pass:

```bash
# Runner reads model from subagent frontmatter
Claude -m "gemini-2.5-pro" -p "Review this codebase..."
```

### Supervisor Integration

The supervisor resolves model tiers from subagent frontmatter:

1. Task specifies `model: pro` in TODO.md metadata
2. Supervisor reads `models/pro.md` frontmatter for concrete model ID
3. Dispatches runner with `--model` flag set to the resolved model

## Fallback Chains (t132.4)

Each tier supports a configurable fallback chain that goes beyond the simple primary/fallback pair. When a provider fails (API error, timeout, rate limit), the system walks the chain until a healthy provider is found, including gateway providers like OpenRouter and Cloudflare AI Gateway.

Add `fallback-chain:` to any model tier's YAML frontmatter for per-agent overrides:

```yaml
fallback-chain:
  - anthropic/claude-sonnet-4-20250514
  - openai/gpt-4.1
  - google/gemini-2.5-pro
  - openrouter/anthropic/claude-sonnet-4-20250514
```

Global defaults are configured in `configs/fallback-chain-config.json`. See `tools/ai-assistants/fallback-chains.md` for full documentation.

## Adding New Models

1. Create a new subagent file in this directory
2. Set `model:` in YAML frontmatter to the provider/model ID
3. Optionally add `fallback-chain:` for per-agent chain override
4. Add to the tier mapping in `model-routing.md`
5. Add to `compare-models-helper.sh` MODEL_DATA if tracking pricing
6. Run `model-registry-helper.sh sync --force` to update the registry
7. Run `model-registry-helper.sh check` to verify availability

## Model Registry

The model registry (`model-registry-helper.sh`) maintains a SQLite database of all known models, synced from three sources:

1. **Subagent frontmatter** — tier definitions from `models/*.md`
2. **Embedded data** — pricing/capabilities from `compare-models-helper.sh`
3. **Provider APIs** — live model discovery from configured providers

```bash
model-registry-helper.sh sync          # Sync from all sources
model-registry-helper.sh status        # Registry health and tier mapping
model-registry-helper.sh check         # Verify subagent models exist
model-registry-helper.sh suggest       # New models worth adding
model-registry-helper.sh deprecations  # Deprecated/unavailable models
model-registry-helper.sh diff          # Registry vs local config
```

The registry runs automatically on `aidevops update` and can be added to cron for periodic sync. Storage: `~/.aidevops/.agent-workspace/model-registry.db`

## Related

- `tools/ai-assistants/fallback-chains.md` — Fallback chain configuration and gateway providers
- `tools/context/model-routing.md` — Cost-aware routing rules
- `compare-models-helper.sh discover` — Detect available providers
- `model-registry-helper.sh` — Provider/model registry with periodic sync
- `fallback-chain-helper.sh` — Fallback chain resolution with trigger detection
- `tools/ai-assistants/headless-dispatch.md` — CLI dispatch with model selection
