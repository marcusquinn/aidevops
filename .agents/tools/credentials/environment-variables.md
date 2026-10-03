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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Environment Variables Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Priority**: Environment variables > .env files > config files > defaults
- **OpenAI**: `OPENAI_API_KEY` (sk-...), `OPENAI_BASE_URL`
- **Anthropic**: `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
- **Others**: `GOOGLE_API_KEY`, `AZURE_OPENAI_API_KEY`
- **Check keys**: check whether variables are set without printing their values
- **Test OpenAI**: `curl -H "Authorization: Bearer $OPENAI_API_KEY" https://api.openai.com/v1/models | head -20`

<!-- AI-CONTEXT-END -->

## Supported Variables

| Provider | Variable | Notes |
|----------|----------|-------|
| OpenAI | `OPENAI_API_KEY` | Format: `sk-...` |
| OpenAI | `OPENAI_BASE_URL` | Custom endpoint (optional) |
| Anthropic | `ANTHROPIC_API_KEY` | For Claude models |
| Anthropic | `ANTHROPIC_BASE_URL` | Custom endpoint (optional) |
| Google | `GOOGLE_API_KEY` | Gemini models |
| Azure | `AZURE_OPENAI_API_KEY` | Azure OpenAI |

## Configuration Priority

1. Environment variables (terminal session) — highest priority
2. `.env` files (project-specific override)
3. Configuration files (fallback)
4. Default values (last resort)

## How It Works

Tools read environment variables automatically — no additional configuration needed.
Store secrets with `aidevops secret set NAME` or in `~/.config/aidevops/credentials.sh` with mode 600. Never commit secret values in `.env` or configuration files.

## Troubleshooting

```bash
# Verify a key is set without exposing it
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  printf 'OpenAI key is set\n'
fi

# Test API connectivity
curl -H "Authorization: Bearer $OPENAI_API_KEY" https://api.openai.com/v1/models | head -20
```

**Common issues:**

1. Key not found — verify it's exported without printing it
2. Wrong format — OpenAI keys start with `sk-`
3. Permissions — ensure key has required scopes
4. Rate limits — check API usage dashboard
