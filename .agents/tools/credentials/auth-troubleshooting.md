# Auth Troubleshooting

Use this when a user reports "Key Missing", auth errors, or the model has stopped responding.

All recovery commands work from any terminal — no working model session required.

## Important: OAuth only — no API keys

The pool uses **OAuth only** (Claude Pro/Max subscription). API keys are not used and not needed.

- `opencode auth login` prompts for an API key — **do not use this for OAuth**
- The correct OAuth setup path is `aidevops model-accounts-pool add anthropic` (opens browser)
- Or via OpenCode TUI: `Ctrl+A` → Anthropic → Login with Claude.ai

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
aidevops model-accounts-pool import claude-cli    # import from existing Claude CLI auth
aidevops model-accounts-pool remove <p> <email>   # remove an account
```

## Key diagnostic facts

- `rotate` writes the new account into `auth.json` immediately — OpenCode must restart to pick it up
- `reset-cooldowns` clears the **pool file** cooldowns only; the in-memory token endpoint cooldown in a running OpenCode process requires a restart or `/model-accounts-pool reset-cooldowns` inside an active session
- Pool file: `~/.aidevops/oauth-pool.json` — if corrupt or missing, `add` recreates it
- "Key Missing" means the loader returned `{}`: pool is empty, all tokens expired/errored, or OpenCode's auth state was reset
- `assign-pending` is needed when OAuth completes but the email lookup fails — the token is saved as `_pending_<provider>` and stranded until assigned
