---
description: Environment variables integration for credentials
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Environment Variables Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Priority**: Environment variables > .env files > config files > defaults
- **OpenAI**: `OPENAI_API_KEY` (sk-...), `OPENAI_BASE_URL`
- **Anthropic**: `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
- **Others**: `AI_GATEWAY_API_KEY`, `GOOGLE_API_KEY`, `AZURE_OPENAI_API_KEY`
- **Check keys**: `env | grep -E "(OPENAI|ANTHROPIC|CLAUDE)_API_KEY"`
- **Test OpenAI**: `curl -H "Authorization: Bearer $OPENAI_API_KEY" https://api.openai.com/v1/models | head -20`

<!-- AI-CONTEXT-END -->

## Supported Variables

| Provider | Variable | Notes |
|----------|----------|-------|
| OpenAI | `OPENAI_API_KEY` | Format: `sk-...` |
| OpenAI | `OPENAI_BASE_URL` | Custom endpoint (optional) |
| Anthropic | `ANTHROPIC_API_KEY` | For Claude models |
| Anthropic | `ANTHROPIC_BASE_URL` | Custom endpoint (optional) |
| DSPyGround | `AI_GATEWAY_API_KEY` | AI Gateway integration |
| Google | `GOOGLE_API_KEY` | Gemini models |
| Azure | `AZURE_OPENAI_API_KEY` | Azure OpenAI |

## Configuration Priority

1. Environment variables (terminal session) — highest priority
2. `.env` files (project-specific override)
3. Configuration files (fallback)
4. Default values (last resort)

## How It Works

Tools read environment variables automatically — no additional configuration needed.

**DSPy** checks environment first:

```python
api_key = os.getenv("OPENAI_API_KEY", config_fallback)
lm = dspy.LM(model="openai/gpt-3.5-turbo", api_key=api_key)
```

**`.env` files** reference your session variables:

```bash
OPENAI_API_KEY=${OPENAI_API_KEY}
```

## Troubleshooting

```bash
# Verify keys are set
env | grep -E "(OPENAI|ANTHROPIC|CLAUDE)_API_KEY"

# Check OpenAI key format (must start with sk-)
echo $OPENAI_API_KEY | grep -E "^sk-"

# Test API connectivity
curl -H "Authorization: Bearer $OPENAI_API_KEY" https://api.openai.com/v1/models | head -20
```

**Common issues:**

1. Key not found — `echo $OPENAI_API_KEY` to verify it's exported
2. Wrong format — OpenAI keys start with `sk-`
3. Permissions — ensure key has required scopes
4. Rate limits — check API usage dashboard
