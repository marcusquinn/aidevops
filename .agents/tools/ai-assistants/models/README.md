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

## Adding New Models

1. Create a new subagent file in this directory
2. Set `model:` in YAML frontmatter to the provider/model ID
3. Add to the tier mapping in `model-routing.md`
4. Run `compare-models-helper.sh discover --probe` to verify access

## Related

- `tools/context/model-routing.md` — Cost-aware routing rules
- `compare-models-helper.sh discover` — Detect available providers
- `tools/ai-assistants/headless-dispatch.md` — CLI dispatch with model selection
