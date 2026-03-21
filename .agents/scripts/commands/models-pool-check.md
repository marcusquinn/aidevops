---
description: Check OAuth pool health, test token validity, and manage provider accounts
agent: Build+
mode: subagent
---

Check the health and status of all OAuth pool accounts across providers.

## Workflow

1. Call the `model-accounts-pool` tool with `{"action": "check"}` to run a comprehensive health check across all providers
2. Route based on the check output:

### Routing rules

**Path A — No accounts configured:**
The check output contains "No accounts in any pool." Present the "Adding an account" guide below.

**Path B — All accounts healthy:**
Every account shows `Status: active`, `Token: expires in ...`, and `Validity: OK` (no `EXPIRED`, `INVALID`, `auth-error`, or `Refresh token: MISSING` lines). Report the health summary — no action needed.

**Path C — One or more accounts unhealthy:**
Any account shows one of: `Token: EXPIRED`, `Validity: INVALID`, `Status: auth-error`, or `Refresh token: MISSING`. Present the specific issues and guide the user to the relevant fix:
- `EXPIRED` / `INVALID` → "Updating/refreshing an account" section
- `Refresh token: MISSING` → re-add the account with `oauth-pool-helper.sh add <provider>`
- `Status: auth-error` → "Updating/refreshing an account" section

## Shell Commands

Users can also manage accounts directly from the terminal:

```bash
# Add an account (opens browser for OAuth)
oauth-pool-helper.sh add anthropic       # Claude Pro/Max
oauth-pool-helper.sh add openai          # ChatGPT Plus/Pro

# Health check (token expiry, validity, status)
oauth-pool-helper.sh check               # All providers
oauth-pool-helper.sh check anthropic     # Specific provider
oauth-pool-helper.sh check openai        # Specific provider

# List accounts
oauth-pool-helper.sh list

# Remove an account (provider is required)
oauth-pool-helper.sh remove anthropic user@example.com
oauth-pool-helper.sh remove openai user@example.com
```

Rotate and reset-cooldowns are MCP-tool-only (no CLI equivalent):

```text
model-accounts-pool {"action": "rotate", "provider": "anthropic"}
model-accounts-pool {"action": "rotate", "provider": "openai"}
model-accounts-pool {"action": "reset-cooldowns", "provider": "anthropic"}
model-accounts-pool {"action": "reset-cooldowns", "provider": "openai"}
```

## Account Management Guide

When reporting results, include relevant guidance from this section based on what the user needs.

### Adding an account

**Option A — Shell (recommended):**

Run in your terminal:

```bash
oauth-pool-helper.sh add anthropic    # Claude Pro/Max
oauth-pool-helper.sh add openai       # ChatGPT Plus/Pro
```

This opens your browser for OAuth, then saves the token to the pool. Restart OpenCode after adding.

**Option B — OpenCode TUI:**

1. Press Ctrl+A in the TUI
2. Select the pool provider (Anthropic Pool, OpenAI Pool, Cursor Pool)
3. Enter your account email when prompted
4. Complete the OAuth flow in your browser
5. Paste the authorization code back
6. After success, switch to the main provider (Anthropic/OpenAI) and select a model — the pool provider is for account management only

Repeat to add multiple accounts. The pool rotates between them automatically when one hits rate limits.

### Updating/refreshing an account

Tokens refresh automatically. If an account shows `auth-error`:

Run `oauth-pool-helper.sh add <provider>` with the same email address — the existing account will be updated with fresh tokens.

### Removing an account

```bash
oauth-pool-helper.sh remove anthropic user@example.com
```

Or use the `model-accounts-pool` tool:

- `{"action": "remove", "provider": "anthropic", "email": "<email>"}`
- `{"action": "remove", "provider": "openai", "email": "<email>"}`

### Rotating manually

Always specify the provider — omitting it may rotate the wrong pool in multi-provider setups:

- `{"action": "rotate", "provider": "anthropic"}`
- `{"action": "rotate", "provider": "openai"}`

### Resetting cooldowns

If all accounts are rate-limited and you want to retry immediately — specify the provider:

- `{"action": "reset-cooldowns", "provider": "anthropic"}`
- `{"action": "reset-cooldowns", "provider": "openai"}`

### Troubleshooting: Pool providers not showing in Ctrl+A

If the pool providers (Anthropic Pool, OpenAI Pool, Cursor Pool) don't appear:

1. **Check plugin is installed**: Run `aidevops setup` — this registers the plugin in opencode.json
2. **Check opencode.json**: Verify `~/.config/opencode/opencode.json` has the plugin in its `"plugin"` array:

   ```json
   "plugin": ["file:///Users/<you>/.aidevops/agents/plugins/opencode-aidevops/index.mjs"]
   ```

3. **Check symlink exists**: `ls -la ~/.config/opencode/plugins/opencode-aidevops`
4. **Restart OpenCode**: The plugin loads at startup — changes require a restart
5. **Use shell commands instead**: `oauth-pool-helper.sh add anthropic` works independently of the TUI

## Notes

- Pool file: `~/.aidevops/oauth-pool.json` (600 permissions, never commit)
- Tokens are provider-specific: Anthropic tokens work with Claude models, OpenAI tokens with GPT/o-series models
- The pool auto-rotates on rate limiting — manual rotation is rarely needed
- Token endpoint cooldowns are in-memory (reset on OpenCode restart)
- Per-account cooldowns persist in the pool file
- Shell commands work independently of OpenCode — use them when the TUI auth flow is unavailable
