<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Auth Troubleshooting

Use when a user reports "Key Missing", auth errors, or the model has stopped responding.
All recovery commands work from any terminal — no working model session required.

> **Anthropic uses OAuth only** (Claude Pro/Max). `opencode auth login` prompts for an API key — do not use it for OAuth. Use `aidevops model-accounts-pool add anthropic` (opens browser) or OpenCode TUI: `Ctrl+A` → Anthropic → Login with Claude.ai.

## Recovery flow (run in order)

```bash
aidevops update                                   # ensure latest version first
aidevops model-accounts-pool status               # 1. pool health at a glance
aidevops model-accounts-pool check                # 2. live token validity per account
aidevops model-accounts-pool rotate anthropic     # 3. switch account if rate-limited
aidevops model-accounts-pool reset-cooldowns      # 4. clear cooldowns if all accounts stuck
aidevops model-accounts-pool add anthropic        # 5. re-add account if pool empty
```

## Symptom → command

| Symptom | Command |
|---------|---------|
| `rate-limited` in status | `rotate anthropic` |
| All accounts in cooldown | `reset-cooldowns` |
| `auth-error` in status | `add anthropic` (re-auth via browser) |
| Pool empty (no accounts) | `add anthropic` or `import claude-cli` |
| Re-authed but still broken | `assign-pending anthropic` |
| Error affects all providers | `reset-cooldowns all` then `check` |
| Google Gemini CLI rate-limited | `rotate google` |
| Google token expired | `refresh google` or `add google` |

## Command reference

| Command | Description |
|---------|-------------|
| `status` | Aggregate counts per provider |
| `list` | Per-account detail + expiry |
| `check [provider]` | Live API validity test |
| `rotate [provider]` | Switch to next available account NOW |
| `reset-cooldowns [all]` | Clear rate-limit cooldowns (pool file only) |
| `assign-pending <provider>` | Assign stranded pending token |
| `add anthropic` | Claude Pro/Max — browser OAuth |
| `add openai` | ChatGPT Plus/Pro — browser OAuth |
| `add cursor` | Cursor Pro — reads from local IDE |
| `add google` | Google AI Pro/Ultra/Workspace — browser OAuth |
| `import claude-cli` | Import from existing Claude CLI auth |
| `remove <provider> <email>` | Remove an account |

All commands prefixed with `aidevops model-accounts-pool`.

## Google AI Pool

Supports Google AI Pro (~$25/mo), Ultra (~$65/mo), and Workspace with Gemini add-on. Tokens injected as `GOOGLE_OAUTH_ACCESS_TOKEN` (ADC bearer token) — picked up by Gemini CLI, Vertex AI SDK, and `generativelanguage.googleapis.com` automatically. Google auth failures never affect Anthropic/OpenAI/Cursor providers.

**Health check:** `aidevops model-accounts-pool check google` validates against `generativelanguage.googleapis.com/v1beta/models`.

## Key diagnostic facts

- "Key Missing" = plugin didn't load or pool is empty — check `aidevops model-accounts-pool status`.
- `rotate` updates `process.env.ANTHROPIC_API_KEY` (and `OPENAI_API_KEY`, `GOOGLE_OAUTH_ACCESS_TOKEN`) and `auth.json` immediately — takes effect on the next API call.
- `reset-cooldowns` clears **pool file** cooldowns only; in-memory cooldown in a running process requires a restart or `/model-accounts-pool reset-cooldowns` inside an active session.
- `assign-pending` needed when OAuth completes but email lookup fails — token saved as `_pending_<provider>` until assigned.
- Pool file: `~/.aidevops/oauth-pool.json` — if corrupt or missing, `add` recreates it.
- If `ANTHROPIC_API_KEY` is set in your shell (e.g. `.bashrc`), pool injection overrides it at startup. Remove manual API key env vars to avoid confusion.
- Google tokens expire after ~1 hour (standard OAuth2). Pool auto-refreshes via stored refresh token; if refresh fails, re-auth with `add google`.
