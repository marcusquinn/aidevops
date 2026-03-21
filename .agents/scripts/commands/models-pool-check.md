---
description: Check OAuth pool health, test token validity, and manage provider accounts
agent: Build+
mode: subagent
---

Check the health and status of all OAuth pool accounts across providers.

## Workflow

1. Call the `model-accounts-pool` tool with `{"action": "check"}` to run a comprehensive health check across all providers
2. Present the results to the user
3. If the tool returns a message about no accounts, include the "Adding an account" guide below

## Account Management Guide

When reporting results, include relevant guidance from this section based on what the user needs.

### Adding an account

1. Run `opencode auth login` (or press Ctrl+A in the TUI)
2. Select the pool provider:
   - **Anthropic Pool** — for Claude Pro/Max subscriptions
   - **OpenAI Pool** — for ChatGPT Plus/Pro subscriptions
   - **Cursor Pool** — for Cursor Pro subscriptions
3. Enter your account email when prompted
4. Complete the OAuth flow in your browser
5. Paste the authorization code back into the terminal
6. After success, switch to the main provider (Anthropic/OpenAI) and select a model — the pool provider is for account management only, not for chatting

Repeat to add multiple accounts. The pool rotates between them automatically when one hits rate limits.

### Updating/refreshing an account

Tokens refresh automatically. If an account shows `auth-error`:

1. Run `opencode auth login` and select the same pool provider
2. Enter the same email address
3. Complete the OAuth flow — the existing account will be updated with fresh tokens

### Removing an account

Use the `model-accounts-pool` tool: `{"action": "remove", "provider": "<provider>", "email": "<email>"}`

### Rotating manually

Use the `model-accounts-pool` tool: `{"action": "rotate", "provider": "<provider>"}`

### Resetting cooldowns

If all accounts are rate-limited and you want to retry immediately:
Use the `model-accounts-pool` tool: `{"action": "reset-cooldowns", "provider": "<provider>"}`

### Troubleshooting: Pool providers not showing in Ctrl+A

If the pool providers (Anthropic Pool, OpenAI Pool, Cursor Pool) don't appear:

1. **Check plugin is installed**: Run `aidevops setup` — this registers the plugin in opencode.json
2. **Check opencode.json**: Verify `~/.config/opencode/opencode.json` has the plugin in its `"plugin"` array:

   ```json
   "plugin": ["file:///Users/<you>/.aidevops/agents/plugins/opencode-aidevops/index.mjs"]
   ```

3. **Check symlink exists**: `ls -la ~/.config/opencode/plugins/opencode-aidevops`
4. **Restart OpenCode**: The plugin loads at startup — changes require a restart
5. **Check OpenCode version**: Pool providers require OpenCode v1.2.30+

## Notes

- Pool file: `~/.aidevops/oauth-pool.json` (600 permissions, never commit)
- Tokens are provider-specific: Anthropic tokens work with Claude models, OpenAI tokens with GPT/o-series models
- The pool auto-rotates on rate limiting — manual rotation is rarely needed
- Token endpoint cooldowns are in-memory (reset on OpenCode restart)
- Per-account cooldowns persist in the pool file
