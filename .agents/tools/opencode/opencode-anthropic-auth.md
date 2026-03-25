---
description: Anthropic OAuth authentication plugin for OpenCode
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
---

# OpenCode Anthropic Auth Plugin

> **v1.2.30+**: The built-in `anthropic-auth` plugin was removed. Use the **aidevops OAuth pool** — run `opencode auth login` and select **"Anthropic Pool"**. See [OAuth Pool Setup](#oauth-pool-setup-v1230) below.
>
> **v1.1.36–v1.2.29**: Anthropic OAuth is built into OpenCode natively. The external `opencode-anthropic-auth` npm package is not needed and must NOT be added to `opencode.json` plugins — causes TypeError from double-loading.

<!-- AI-CONTEXT-START -->

## Quick Reference

| Method | OpenCode Version | Use Case |
|--------|-----------------|----------|
| **Anthropic Pool** (aidevops) | v1.2.30+ (required), all versions (recommended) | Multi-account OAuth with rotation |
| **Claude Pro/Max OAuth** (built-in) | v1.1.36–v1.2.29 | Single-account OAuth |
| **Manual API Key** | All versions | Existing API keys |

**Setup (v1.2.30+):**
```bash
opencode auth login  # Select: Anthropic Pool → enter email → complete OAuth in browser
# Repeat to add more accounts for automatic rotation
```

**Setup (v1.1.36–v1.2.29):**
```bash
opencode auth login  # Select: Anthropic → Claude Pro/Max
# Or use Anthropic Pool for multi-account rotation (recommended)
```

<!-- AI-CONTEXT-END -->

## OAuth Pool Setup (v1.2.30+)

The aidevops OAuth pool (`oauth-pool.mjs`) replaces the removed built-in auth. It provides the same OAuth flow plus multi-account rotation — when one account hits a 429, requests automatically switch to the next available account.

**Prerequisite:** The aidevops plugin must be registered (done automatically by `aidevops setup.sh`).

```bash
# Verify plugin is registered
if [[ -L ~/.config/opencode/plugins/opencode-aidevops ]] || grep -q "opencode-aidevops" ~/.config/opencode/opencode.json 2>/dev/null; then
  echo "Plugin registered"
else
  echo "Run: aidevops setup"
fi
```

**Adding accounts:**
```bash
opencode auth login
# Select: "Anthropic Pool" (or "Add Account to Pool (Claude Pro/Max)")
# Enter Claude account email → browser opens to claude.ai/oauth/authorize
# Sign in, authorize, copy the authorization code, paste into OpenCode prompt
```

Repeat for additional accounts. Each is stored in `~/.aidevops/oauth-pool.json`.

**Managing the pool:**
```text
/model-accounts-pool list              # Show all accounts with status
/model-accounts-pool status            # Rotation statistics
/model-accounts-pool remove user@example.com
/model-accounts-pool reset-cooldowns   # Clear rate-limit cooldowns
```

**Pool models** (appear in model picker after adding accounts):
- `anthropic-pool/claude-opus-4-6`
- `anthropic-pool/claude-sonnet-4-6`
- `anthropic-pool/claude-haiku-4-5`

All show $0 cost (covered by Claude Pro/Max subscription).

**Credentials:** `~/.aidevops/oauth-pool.json` (600 permissions, do not commit).

## Authentication Methods

### 1. Claude Pro/Max OAuth — Built-in (v1.1.36–v1.2.29 only)

> **v1.2.30+**: Use the [aidevops OAuth pool](#oauth-pool-setup-v1230) instead.

```bash
opencode auth login
# 1. Select provider: Anthropic
# 2. Choose: Claude Pro/Max
# 3. Browser opens to https://claude.ai/oauth/authorize
# 4. Sign in, authorize, copy authorization code, paste into OpenCode
```

Benefits: No API key costs, automatic token refresh, access to latest models, beta features enabled.

### 2. Create API Key via OAuth

```bash
opencode auth login
# 1. Select provider: Anthropic
# 2. Choose: Create an API Key
# 3. Browser opens to https://console.anthropic.com/oauth/authorize
# 4. Sign in, authorize, copy code, paste → API key auto-created and stored
```

### 3. Manual API Key Entry

```bash
opencode auth login
# 1. Select provider: Anthropic
# 2. Choose: Manually enter API Key
# 3. Paste your key from console.anthropic.com
```

Use when: you already have an API key, prefer manual management, or organization requires specific provisioning.

## How It Works

### OAuth Flow (PKCE)

1. **Authorization:** Generates PKCE challenge, opens browser to Anthropic OAuth endpoint
2. **Token Exchange:** Code + verifier → access_token + refresh_token
3. **API Usage:** Injects `Authorization: Bearer {access_token}` + beta feature flags; prefixes tool names with `oc_` (stripped from responses)
4. **Token Refresh:** Monitors expiration, refreshes automatically

### Beta Features (auto-enabled)

- `oauth-2025-04-20` — OAuth support
- `interleaved-thinking-2025-05-14` — Extended thinking
- `claude-code-20250219` — Claude Code features (if requested)

## Troubleshooting

| Symptom | Solution |
|---------|----------|
| OAuth authorization fails | Check correct account signed in, active subscription, clear browser cookies for anthropic.com |
| Token refresh failures (401) | `opencode auth logout && opencode auth login`; check `~/.config/opencode/auth.json` for valid refresh_token |
| "Anthropic Pool" missing (v1.2.30+) | aidevops plugin not registered — re-run `aidevops setup` |
| Plugin not detected (pre-v1.1.36) | `npm list -g opencode-anthropic-auth`; reinstall if missing; restart OpenCode |
| API key creation fails | Check Anthropic Console access and org permissions; try manual key as fallback |
| Pro/Max OAuth shows non-zero costs | Verify `type: "oauth"` in `~/.config/opencode/auth.json`; re-authenticate |

**Switching methods:**
```bash
opencode auth logout  # Clear current credentials
opencode auth login   # Choose new method
```

**Verify authentication:**
```bash
opencode auth status
opencode run "Hello, Claude!" --model anthropic/claude-sonnet-4-6
```

**Debug:**
```bash
DEBUG=opencode:* opencode run "test" --model anthropic/claude-sonnet-4-6
jq '.anthropic' ~/.config/opencode/auth.json  # Check token expiration
```

## Comparison

| Feature | Built-in OAuth (v1.1.36–v1.2.29) | aidevops Pool (v1.2.30+, all versions) | Manual API Key |
|---------|----------------------------------|----------------------------------------|----------------|
| Claude Pro/Max cost | $0 | $0 | Standard rates |
| Auto token refresh | Yes | Yes | N/A |
| Beta features | Auto-enabled | Auto-enabled | Manual |
| Multi-account rotation | No | Yes | No |
| Best for | v1.1.36–v1.2.29 subscribers | v1.2.30+ (required); all (recommended) | API-only users |

## Security

- PKCE prevents authorization code interception
- Tokens stored locally, never transmitted to third parties
- **OAuth pool tokens:** `~/.aidevops/oauth-pool.json` (0600)
- **Built-in OAuth tokens (v1.1.36–v1.2.29):** `~/.config/opencode/auth.json`
- Use OAuth for personal accounts; use manual keys for CI/CD
- Never commit credential files; monitor usage at console.anthropic.com

## Integration with aidevops

`setup.sh` registers the aidevops plugin automatically. The external `opencode-anthropic-auth` npm package is not installed — removed in aidevops v2.90.0 when OpenCode v1.1.36 made it redundant.

**Recommended configuration:**
- Primary agent (Build+): aidevops OAuth pool for zero-cost usage with rotation
- CI/CD workflows: manual API key method
- Multiple accounts: add 2–3 Claude Pro/Max accounts for uninterrupted sessions

## References

- **Plugin Repository**: https://github.com/anomalyco/opencode-anthropic-auth
- **OpenCode Plugins**: https://opencode.ai/docs/plugins
- **Anthropic OAuth**: https://docs.anthropic.com/en/api/oauth
- `tools/opencode/opencode-openai-auth.md` — OpenAI Pro pool (same architecture)
- `tools/opencode/opencode.md` — OpenCode integration overview
- `tools/credentials/api-key-management.md` — API key management
- `aidevops/setup.md` — Setup script details
