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
opencode auth login
# Select: OpenAI Pool
# Enter your ChatGPT account email
# Complete OAuth flow in browser (redirects to localhost:1455)
# Copy the "code" parameter from the redirect URL
# Paste into the OpenCode prompt

# Optionally add more accounts for automatic rotation
opencode auth login
# Select: OpenAI Pool → enter second account email

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
| Redirect URI | `console.anthropic.com/oauth/code/callback` | `localhost:1455/auth/callback` |
| Scopes | `org:create_api_key user:profile ...` | `openid profile email offline_access` |
| Account ID | N/A | `chatgpt_account_id` (from JWT claims) |
| Auth.json fields | `type, refresh, access, expires` | `type, refresh, access, expires, accountId` |

## OAuth Flow

OpenAI uses a local redirect server (port 1455) for its built-in OAuth flow.
The pool's add-account flow uses the same redirect URI with a code-paste UX:

1. Browser opens to `https://auth.openai.com/oauth/authorize`
2. User signs in with their ChatGPT Plus/Pro account
3. Browser redirects to `http://localhost:1455/auth/callback?code=...`
4. User copies the `code` parameter from the URL
5. User pastes the code into the OpenCode terminal prompt
6. Pool exchanges the code for tokens and stores them

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
cat ~/.aidevops/oauth-pool.json | jq -r '.openai[].email'
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
- Rotate tokens by re-running `opencode auth login` → OpenAI Pool

## Related Documentation

- `tools/opencode/opencode-anthropic-auth.md` — Anthropic pool (same architecture)
- `tools/opencode/opencode.md` — OpenCode integration overview
