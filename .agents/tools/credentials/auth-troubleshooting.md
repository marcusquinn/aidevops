# Auth Troubleshooting

Use when a user reports "Key Missing", auth errors, or the model has stopped responding.
All recovery commands work from any terminal — no working model session required.

**Anthropic uses OAuth only** (Claude Pro/Max). `opencode auth login` prompts for an API key — do not use it for OAuth. Use `aidevops model-accounts-pool add anthropic` (opens browser) or OpenCode TUI: `Ctrl+A` → Anthropic → Login with Claude.ai.

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

## Full command reference

```bash
aidevops model-accounts-pool status               # aggregate counts per provider
aidevops model-accounts-pool list                 # per-account detail + expiry
aidevops model-accounts-pool check                # live API validity test
aidevops model-accounts-pool rotate [provider]    # switch to next available account NOW
aidevops model-accounts-pool reset-cooldowns      # clear rate-limit cooldowns (pool file)
aidevops model-accounts-pool assign-pending <p>   # assign stranded pending token
aidevops model-accounts-pool add anthropic        # Claude Pro/Max — browser OAuth
aidevops model-accounts-pool add openai           # ChatGPT Plus/Pro — browser OAuth
aidevops model-accounts-pool add cursor           # Cursor Pro — reads from local IDE
aidevops model-accounts-pool add google           # Google AI Pro/Ultra/Workspace — browser OAuth
aidevops model-accounts-pool import claude-cli    # import from existing Claude CLI auth
aidevops model-accounts-pool remove <p> <email>   # remove an account
```

## Google AI Pool

Supports subscription-based plans (Google AI Pro ~$25/mo, Ultra ~$65/mo, Workspace with Gemini add-on). Tokens injected as `GOOGLE_OAUTH_ACCESS_TOKEN` (ADC bearer token) — picked up by Gemini CLI, Vertex AI SDK, and `generativelanguage.googleapis.com` automatically.

**Isolation guarantee:** Google auth failures never affect Anthropic/OpenAI/Cursor providers. A Google 429 or auth error only puts the Google pool into cooldown.

**Health check:** `aidevops model-accounts-pool check google` validates against `generativelanguage.googleapis.com/v1beta/models`.

## Key diagnostic facts

- Token injection uses `process.env.ANTHROPIC_API_KEY` (and `OPENAI_API_KEY`, `GOOGLE_OAUTH_ACCESS_TOKEN`) — works on all OpenCode versions; updated on rotation/refresh without restart.
- `rotate` updates the env var and `auth.json` immediately — takes effect on the next API call.
- `reset-cooldowns` clears **pool file** cooldowns only; in-memory cooldown in a running OpenCode process requires a restart or `/model-accounts-pool reset-cooldowns` inside an active session.
- Pool file: `~/.aidevops/oauth-pool.json` — if corrupt or missing, `add` recreates it.
- "Key Missing" = plugin didn't load or pool is empty — check `aidevops model-accounts-pool status`.
- `assign-pending` needed when OAuth completes but email lookup fails — token saved as `_pending_<provider>` until assigned.
- If `ANTHROPIC_API_KEY` is set in your shell (e.g. `.bashrc`), pool injection overrides it at startup. Remove manual API key env vars to avoid confusion.
- Google tokens expire after ~1 hour (standard OAuth2). Pool auto-refreshes via stored refresh token; if refresh fails, re-auth with `add google`.
