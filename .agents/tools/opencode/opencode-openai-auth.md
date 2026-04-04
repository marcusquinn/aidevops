---
description: OpenAI OAuth authentication pool for OpenCode (ChatGPT Plus/Pro)
mode: subagent
tools:
  read: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OpenCode OpenAI Auth Pool (t1548)

Multi-account OAuth pool for ChatGPT Plus/Pro accounts in OpenCode. Same token injection architecture as the Anthropic pool.

## Quick Reference

- **Provider ID**: `openai-pool` (account management), `openai` (model usage)
- **Pool file**: `~/.aidevops/oauth-pool.json` (key `openai`) — 0600 permissions, never commit
- **OAuth issuer**: `https://auth.openai.com`
- **Client ID**: `app_EMoamEEZ73f0CkXaXp7hrann`

**Setup** (device auth — recommended):

```bash
aidevops model-accounts-pool add openai
# Go to: https://auth.openai.com/codex/device and enter the displayed code

# Fallback (callback URL flow)
AIDEVOPS_OPENAI_ADD_MODE=callback aidevops model-accounts-pool add openai
```

**Manage accounts:**

```bash
/model-accounts-pool list provider=openai
/model-accounts-pool status provider=openai
/model-accounts-pool rotate provider=openai
/model-accounts-pool remove email=user@example.com provider=openai
/model-accounts-pool reset-cooldowns provider=openai

# List emails only (never expose token values)
jq -r '.openai[].email' ~/.aidevops/oauth-pool.json
```

## Architecture

Token injection flow: LRU active account → injected into `openai` provider's `auth.json` on session start → rotated on 429 → expired tokens refreshed via `grant_type: refresh_token`.

### Key Differences from Anthropic Pool

| Aspect | Anthropic | OpenAI |
|--------|-----------|--------|
| Token endpoint | `platform.claude.com/v1/oauth/token` | `auth.openai.com/oauth/token` |
| Body format | JSON | `application/x-www-form-urlencoded` |
| Primary auth UX | Browser callback | Codex device auth (`auth.openai.com/codex/device`) |
| Callback fallback | N/A | `localhost:1455/auth/callback` (`AIDEVOPS_OPENAI_ADD_MODE=callback`) |
| Scopes | `org:create_api_key user:profile ...` | `openid profile email offline_access` |
| Account ID | N/A | `chatgpt_account_id` (from JWT claims) |
| Auth.json fields | `type, refresh, access, expires` | `type, refresh, access, expires, accountId` |

## Pool File Structure

```json
{
  "openai": [{
    "email": "user@example.com",
    "refresh": "<refresh_token>",
    "access": "<access_token>",
    "expires": 1234567890000,
    "added": "2026-03-20T00:00:00.000Z",
    "lastUsed": "2026-03-20T00:00:00.000Z",
    "status": "active",
    "cooldownUntil": null,
    "accountId": "chatgpt_account_id_value"
  }]
}
```

## Related

- `tools/opencode/opencode-anthropic-auth.md` — Anthropic pool (same architecture)
- `tools/opencode/opencode.md` — OpenCode integration overview
