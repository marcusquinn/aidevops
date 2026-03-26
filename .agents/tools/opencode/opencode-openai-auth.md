---
description: OpenAI OAuth authentication pool for OpenCode (ChatGPT Plus/Pro)
mode: subagent
tools:
  read: true
  bash: true
---

# OpenCode OpenAI Auth Pool (t1548)

Multi-account OAuth pool for ChatGPT Plus/Pro accounts in OpenCode.
Uses the same token injection architecture as the Anthropic pool.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: OAuth authentication for ChatGPT Plus/Pro accounts in OpenCode
- **Provider ID**: `openai-pool` (account management), `openai` (model usage)
- **Pool file**: `~/.aidevops/oauth-pool.json` (key `openai`)
- **OAuth issuer**: `https://auth.openai.com`
- **Client ID**: `app_EMoamEEZ73f0CkXaXp7hrann`

**Quick Setup**:

```bash
# Add your first ChatGPT Plus/Pro account to the pool
aidevops model-accounts-pool add openai
# Default flow: OpenAI Codex device auth (recommended)
# You will see:
#   Go to: https://auth.openai.com/codex/device
#   Enter code: XXXX-XXXXX

# Optional fallback (callback URL flow)
AIDEVOPS_OPENAI_ADD_MODE=callback aidevops model-accounts-pool add openai

# Manage accounts
# /model-accounts-pool list provider=openai
# /model-accounts-pool status provider=openai
# /model-accounts-pool remove email=user@example.com provider=openai
```

<!-- AI-CONTEXT-END -->

## Architecture

The OpenAI pool uses the same token injection architecture as the Anthropic pool:

1. **Pool storage**: Accounts stored in `~/.aidevops/oauth-pool.json` under the `openai` key
2. **Token injection**: On session start, the least-recently-used active account's token
   is injected into the built-in `openai` provider's `auth.json` entry
3. **Rotation**: When a 429 is received, the next available account is injected
4. **Refresh**: Expired tokens are refreshed automatically using `grant_type: refresh_token`

### Key Differences from Anthropic Pool

| Aspect | Anthropic | OpenAI |
|--------|-----------|--------|
| Token endpoint | `platform.claude.com/v1/oauth/token` | `auth.openai.com/oauth/token` |
| Body format | JSON | `application/x-www-form-urlencoded` |
| Primary auth UX | Browser callback | Codex device auth (`auth.openai.com/codex/device`) |
| Callback fallback | N/A | `localhost:1455/auth/callback` (optional via `AIDEVOPS_OPENAI_ADD_MODE=callback`) |
| Scopes | `org:create_api_key user:profile ...` | `openid profile email offline_access` |
| Account ID | N/A | `chatgpt_account_id` (from JWT claims) |
| Auth.json fields | `type, refresh, access, expires` | `type, refresh, access, expires, accountId` |

## OAuth Flow

The pool helper uses a **device-auth-first** flow for OpenAI:

1. Run `aidevops model-accounts-pool add openai`
2. Terminal prompts OpenCode headless login flow
3. Browser opens to `https://auth.openai.com/codex/device`
4. User enters the device code shown in terminal
5. OpenCode stores OAuth tokens in `~/.local/share/opencode/auth.json`
6. Pool helper reads those tokens and stores them in `~/.aidevops/oauth-pool.json`

If device auth is unavailable in your environment, set `AIDEVOPS_OPENAI_ADD_MODE=callback` to use the legacy callback URL flow.

## Managing the Pool

Use the `/model-accounts-pool` tool with `provider=openai`:

```text
/model-accounts-pool list provider=openai
/model-accounts-pool status provider=openai
/model-accounts-pool rotate provider=openai
/model-accounts-pool remove email=user@example.com provider=openai
/model-accounts-pool reset-cooldowns provider=openai
```

Or inspect the pool file directly (key names only):

```bash
# List account emails (never expose token values)
jq -r '.openai[].email' ~/.aidevops/oauth-pool.json
```

## Pool File Structure

```json
{
  "openai": [
    {
      "email": "user@example.com",
      "refresh": "<refresh_token>",
      "access": "<access_token>",
      "expires": 1234567890000,
      "added": "2026-03-20T00:00:00.000Z",
      "lastUsed": "2026-03-20T00:00:00.000Z",
      "status": "active",
      "cooldownUntil": null,
      "accountId": "chatgpt_account_id_value"
    }
  ]
}
```

## Security

- Pool file has 0600 permissions (owner-only read/write)
- Tokens are stored locally, never transmitted to third parties
- Do not commit `~/.aidevops/oauth-pool.json` to version control
- Rotate tokens by re-running `aidevops model-accounts-pool add openai`

## Related Documentation

- `tools/opencode/opencode-anthropic-auth.md` — Anthropic pool (same architecture)
- `tools/opencode/opencode.md` — OpenCode integration overview
