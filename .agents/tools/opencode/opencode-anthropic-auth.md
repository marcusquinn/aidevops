---
description: Anthropic OAuth authentication plugin for OpenCode
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
---

# OpenCode Anthropic Auth Plugin

> **v1.2.30+**: The built-in `anthropic-auth` plugin was removed in OpenCode v1.2.30.
> Use the **aidevops OAuth pool** instead — run `opencode auth login` and select
> **"Anthropic Pool"** (provided by the aidevops plugin). See [OAuth Pool Setup](#oauth-pool-setup-v1230) below.
>
> **v1.1.36–v1.2.29**: Anthropic OAuth is built into OpenCode natively.
> The external `opencode-anthropic-auth` npm package is not needed and must NOT be added
> to `opencode.json` plugins — doing so causes a TypeError due to double-loading.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: OAuth authentication for Claude Pro/Max accounts in OpenCode
- **Status (v1.2.30+)**: Built-in auth removed — use aidevops OAuth pool (`opencode auth login` → "Anthropic Pool")
- **Status (v1.1.36–v1.2.29)**: Built-in to OpenCode, no external plugin needed
- **Repository**: https://github.com/anomalyco/opencode-anthropic-auth (historical reference only)

**Authentication Methods**:

| Method | OpenCode Version | Use Case | Requirements |
|--------|-----------------|----------|--------------|
| **Anthropic Pool** (aidevops) | v1.2.30+ (required), all versions (recommended) | Multi-account OAuth with rotation | Claude Pro/Max subscription |
| **Claude Pro/Max OAuth** (built-in) | v1.1.36–v1.2.29 | Single-account OAuth | Claude Pro/Max subscription |
| **Manual API Key** | All versions | Existing API keys | API key from console.anthropic.com |

**Quick Setup (v1.2.30+)**:

```bash
# 1. Ensure aidevops plugin is registered (done by aidevops setup.sh)
# 2. Add your first account to the pool
opencode auth login
# Select: Anthropic Pool
# Enter your Claude account email
# Complete OAuth flow in browser

# 3. Optionally add more accounts for automatic rotation
opencode auth login
# Select: Anthropic Pool → enter second account email

# 4. Manage accounts
# /model-accounts-pool list
# /model-accounts-pool status
# /model-accounts-pool remove user@example.com
```

**Quick Setup (v1.1.36–v1.2.29)**:

```bash
# Built-in OAuth (single account)
opencode auth login
# Select: Anthropic → Claude Pro/Max (or Create an API Key)
# Follow OAuth flow in browser

# Or use the aidevops pool for multi-account rotation (recommended)
opencode auth login
# Select: Anthropic Pool
```

<!-- AI-CONTEXT-END -->

## OAuth Pool Setup (v1.2.30+)

OpenCode v1.2.30 removed the built-in `anthropic-auth` plugin. The aidevops OAuth pool
(`oauth-pool.mjs`) is the replacement. It provides the same OAuth flow with the addition
of multi-account rotation — when one account hits a rate limit (429), requests automatically
switch to the next available account.

### Prerequisites

The aidevops plugin must be registered in OpenCode. This is done automatically by `aidevops setup.sh`.
Verify with:

```bash
if [[ -L ~/.config/opencode/plugins/opencode-aidevops ]] || grep -q "opencode-aidevops" ~/.config/opencode/opencode.json 2>/dev/null; then
  echo "Plugin registered"
else
  echo "Run: aidevops setup"
fi
```

### Adding Accounts

```bash
opencode auth login
# Select: "Anthropic Pool" (or "Add Account to Pool (Claude Pro/Max)")
# Enter your Claude account email when prompted
# A browser window opens to claude.ai/oauth/authorize
# Sign in and authorize the application
# Copy the authorization code from the callback URL
# Paste into the OpenCode prompt
```

Repeat to add additional accounts. Each account is stored in `~/.aidevops/oauth-pool.json`.

### Managing the Pool

Use the `/model-accounts-pool` tool inside any OpenCode session:

```text
/model-accounts-pool list              # Show all accounts with status
/model-accounts-pool status            # Rotation statistics
/model-accounts-pool remove user@example.com  # Remove an account
/model-accounts-pool reset-cooldowns   # Clear rate-limit cooldowns
```

Or use the MCP tool directly:

```bash
# List accounts (key names only — never expose values)
jq -r '.anthropic[].email' ~/.aidevops/oauth-pool.json
```

### Pool File

Credentials are stored in `~/.aidevops/oauth-pool.json` (separate from OpenCode's `auth.json`).
This file contains OAuth tokens — do not commit to version control.

```bash
# Check file permissions (should be 600)
ls -la ~/.aidevops/oauth-pool.json
```

### Using Pool Models

After adding accounts, pool models appear in the model picker as `anthropic-pool/claude-*`:

- `anthropic-pool/claude-opus-4-6`
- `anthropic-pool/claude-sonnet-4-6`
- `anthropic-pool/claude-haiku-4-5`

All models show $0 cost (covered by Claude Pro/Max subscription).

## Overview

The `opencode-anthropic-auth` plugin enables OAuth authentication for Anthropic's Claude models in OpenCode. This allows Claude Pro/Max subscribers to use OpenCode without manually managing API keys, and provides automatic token refresh for seamless sessions.

## Features

- **OAuth 2.0 authentication** with PKCE for Anthropic Console
- **Claude Pro/Max support** - Use your subscription for free API access
- **API Key creation** via OAuth for traditional key-based access
- **Automatic token refresh** - No manual re-authentication needed
- **Beta features** - Auto-enabled extended thinking and other beta features
- **Manual API key fallback** - Traditional API key entry still supported

## Installation

### Built-in (OpenCode v1.1.36–v1.2.29)

> **v1.2.30+**: Built-in auth was removed. Use the [aidevops OAuth pool](#oauth-pool-setup-v1230) instead.

Anthropic OAuth is built into OpenCode v1.1.36–v1.2.29. No installation needed — just run:

```bash
opencode auth login
# Select: Anthropic → Claude Pro/Max
```

### Legacy Installation (pre-v1.1.36 only)

> **Do not use on OpenCode v1.1.36+** — causes TypeError from double-loading.

```bash
# Only for OpenCode versions before v1.1.36
npm install -g opencode-anthropic-auth
```

## Authentication Methods

### 1. Claude Pro/Max OAuth — Built-in (v1.1.36–v1.2.29 only)

> **v1.2.30+**: This built-in option was removed. Use the [aidevops OAuth pool](#oauth-pool-setup-v1230) instead — it provides the same OAuth flow with multi-account rotation.

Best for users on OpenCode v1.1.36–v1.2.29 with active Claude Pro or Max subscriptions who want free API usage.

**Setup**:

```bash
opencode auth login
```

1. Select provider: **Anthropic**
2. Choose: **Claude Pro/Max**
3. Browser opens to `https://claude.ai/oauth/authorize`
4. Sign in with your Claude account
5. Authorize the application
6. Copy the authorization code from the callback URL
7. Paste into OpenCode prompt

**Benefits**:
- No API key costs (covered by subscription)
- Automatic token refresh
- Access to latest models
- Beta features enabled

**Model Access**:
- All Anthropic models available to Pro/Max subscribers
- Zero cost (tracked as $0 in OpenCode)
- Extended thinking modes enabled via beta flags

### 2. Create API Key via OAuth

Creates a traditional API key through OAuth authentication.

**Setup**:

```bash
opencode auth login
```

1. Select provider: **Anthropic**
2. Choose: **Create an API Key**
3. Browser opens to `https://console.anthropic.com/oauth/authorize`
4. Sign in to Anthropic Console
5. Authorize the application
6. Copy the authorization code
7. Paste into OpenCode prompt
8. API key is automatically created and stored

**Benefits**:
- OAuth-based key creation (no manual console access needed)
- Key is automatically configured in OpenCode
- Standard API billing applies

### 3. Manual API Key Entry

Traditional API key entry for existing keys.

**Setup**:

```bash
opencode auth login
```

1. Select provider: **Anthropic**
2. Choose: **Manually enter API Key**
3. Paste your API key from console.anthropic.com

**When to use**:
- You already have an API key
- You prefer manual key management
- Organization requires specific key provisioning

## How It Works

### OAuth Flow (PKCE)

The plugin implements OAuth 2.0 with PKCE (Proof Key for Code Exchange):

1. **Authorization Request**:
   - Generates PKCE challenge and verifier
   - Opens browser to Anthropic OAuth endpoint
   - User authorizes the application

2. **Token Exchange**:
   - User provides authorization code from callback URL
   - Plugin exchanges code + verifier for tokens
   - Receives access_token and refresh_token

3. **API Usage**:
   - Injects `Authorization: Bearer {access_token}` header
   - Adds beta feature flags to `anthropic-beta` header
   - Prefixes tool names with `oc_` (automatically removed in responses)

4. **Token Refresh**:
   - Monitors token expiration
   - Automatically refreshes before expiry
   - Updates stored credentials

### Beta Features

The plugin automatically enables:

- `oauth-2025-04-20` - OAuth support
- `interleaved-thinking-2025-05-14` - Extended thinking
- `claude-code-20250219` - Claude Code features (if requested)

These are injected into all API requests via the `anthropic-beta` header.

### Tool Name Prefixing

To avoid conflicts with Anthropic's internal tools, the plugin:

1. **Outgoing requests**: Prefixes tool names with `oc_`
   - Example: `bash` → `oc_bash`

2. **Incoming responses**: Strips the prefix
   - Example: `oc_bash` → `bash`

This is transparent to users and other components.

## Configuration

### Plugin Location

After installation, the plugin is available globally:

```bash
# Check installation
npm list -g opencode-anthropic-auth

# Plugin path (npm global modules)
$(npm root -g)/opencode-anthropic-auth
```

### OpenCode Detection (pre-v1.1.36 external plugin only)

OpenCode automatically discovers the plugin through the `@opencode-ai/plugin` package interface. No manual configuration needed.

### Stored Credentials

OAuth tokens are stored securely by OpenCode in:

```bash
~/.config/opencode/auth.json
```

**Security notes**:
- File should have 600 permissions (OpenCode handles this)
- Contains refresh_token, access_token, and expiration timestamp
- Do not commit to version control
- Add to `.gitignore` if working in OpenCode config directory

## Usage Examples

### Basic Authentication

> **v1.2.30+**: Use `opencode auth login` and select **Anthropic Pool**.
> **v1.1.36–v1.2.29**: Use built-in **Anthropic → Claude Pro/Max**.
> **pre-v1.1.36**: See [Legacy Installation](#legacy-installation-pre-v1136-only) for external plugin instructions.

```bash
# First-time setup
opencode auth login

# Select Anthropic → Claude Pro/Max (v1.1.36–v1.2.29)
# Or select Anthropic Pool (v1.2.30+)
# Complete OAuth flow
# Plugin handles everything automatically
```

### Switching Authentication Methods

```bash
# Switch from manual API key to OAuth
opencode auth logout  # Clear current credentials
opencode auth login   # Choose OAuth method

# Switch from OAuth to manual key
opencode auth logout
opencode auth login   # Choose manual API key
```

### Verifying Authentication

```bash
# Check current authentication status
opencode auth status

# Test API access
opencode run "Hello, Claude!" --model anthropic/claude-sonnet-4-6
```

## Troubleshooting

### OAuth Authorization Fails

**Symptoms**: Browser opens but authorization fails or returns error.

**Solutions**:
1. Ensure you're signed into the correct account (claude.ai or console.anthropic.com)
2. Check your subscription is active (for Pro/Max method)
3. Clear browser cookies for anthropic.com and retry
4. Use incognito/private window to avoid session conflicts

### Token Refresh Failures

**Symptoms**: API calls fail with 401 Unauthorized after some time.

**Solutions**:
1. Re-authenticate: `opencode auth logout && opencode auth login`
2. Check token expiration in `~/.config/opencode/auth.json`
3. Verify refresh_token is present and valid
4. Check network connectivity to console.anthropic.com

### Plugin Not Detected (pre-v1.1.36 only)

> **v1.2.30+**: The `opencode-anthropic-auth` npm package is not used. If "Anthropic Pool" is missing, the aidevops plugin was not registered — re-run `aidevops setup`.
> **v1.1.36–v1.2.29**: Built-in auth is native; the npm package is not needed and must NOT be installed.

**Symptoms** (pre-v1.1.36 only): Anthropic OAuth options not shown in `opencode auth login`.

**Solutions**:
1. Verify installation: `npm list -g opencode-anthropic-auth`
2. Reinstall: `npm install -g opencode-anthropic-auth`
3. Check OpenCode version (requires plugin support)
4. Restart OpenCode after installation

### API Key Creation Fails

**Symptoms**: OAuth succeeds but API key not created.

**Solutions**:
1. Check Anthropic Console access (account must have API access enabled)
2. Verify organization permissions if using team account
3. Check API endpoint availability: `curl https://api.anthropic.com/api/oauth/claude_cli/create_api_key`
4. Try manual API key method as fallback

### Zero Cost Not Applied

**Symptoms**: Pro/Max OAuth shows non-zero costs in OpenCode.

**Solutions**:
1. Verify authentication type in `~/.config/opencode/auth.json` (`type: "oauth"`)
2. Check plugin is latest version: `npm outdated -g opencode-anthropic-auth`
3. Update if needed: `npm update -g opencode-anthropic-auth`
4. Re-authenticate to refresh config

## Comparison with Other Auth Methods

| Feature | Anthropic OAuth built-in (v1.1.36–v1.2.29) | aidevops OAuth Pool (v1.2.30+, all versions) | Manual API Key |
|---------|---------------------------------------------|----------------------------------------------|----------------|
| **Claude Pro/Max cost** | $0 (subscription) | $0 (subscription) | Standard rates |
| **Auto token refresh** | Yes | Yes | N/A |
| **Beta features** | Auto-enabled | Auto-enabled | Manual |
| **Multi-account rotation** | No | Yes | No |
| **Setup complexity** | Low (OAuth flow) | Low (OAuth flow) | Lowest (paste key) |
| **Best for** | v1.1.36–v1.2.29 subscribers | v1.2.30+ (required); all versions (recommended) | API-only users |

## Security Considerations

### OAuth Security

- Uses PKCE to prevent authorization code interception
- Tokens stored locally (never transmitted to third parties)
- Automatic token rotation reduces exposure window
- Browser-based auth (no credentials stored in plugin)

### API Key Creation

- API keys created via OAuth have same security as manual keys
- Keys are stored in OpenCode's credential store
- Revoke keys at console.anthropic.com if compromised

### Best Practices

1. **Use OAuth for personal accounts** - Better security than long-lived API keys
2. **Use manual keys for CI/CD** - OAuth not suitable for automated systems
3. **Rotate keys regularly** - Even with auto-refresh, periodically re-authenticate
4. **Never commit credentials** - Ensure `~/.config/opencode/auth.json` is gitignored
5. **Monitor API usage** - Check console.anthropic.com for unexpected activity

## Advanced Usage

### Multi-Account Setup

The aidevops OAuth pool supports automatic multi-account rotation. Add multiple accounts:

```bash
# Add first account
opencode auth login
# Select: Anthropic Pool → enter first account email

# Add second account
opencode auth login
# Select: Anthropic Pool → enter second account email
```

The pool automatically rotates to the next available account when one hits a rate limit (429).
Accounts are stored in `~/.aidevops/oauth-pool.json` and persist across sessions.

For teams: each user runs their own aidevops setup and manages their own pool. OAuth tokens
are personal and cannot be shared across users.

### Beta Feature Customization

To customize which beta features are enabled, modify the plugin code:

```javascript
// index.mjs
const mergedBetas = [
  "oauth-2025-04-20",
  "interleaved-thinking-2025-05-14",
  // Add custom beta flags here
].join(",");
```

**Warning**: Modifying the plugin requires forking and maintaining your own version. Coordinate with upstream for feature requests.

### Debugging

Enable verbose logging to troubleshoot authentication issues:

```bash
# Set debug environment variable
DEBUG=opencode:* opencode run "test" --model anthropic/claude-sonnet-4-6

# Check token expiration
jq '.anthropic' ~/.config/opencode/auth.json

# Monitor API requests (requires network inspection tools)
# Use browser DevTools on OAuth flow to inspect requests
```

## Integration with aidevops

### Automatic Setup

`setup.sh` registers the aidevops plugin (which includes the OAuth pool) automatically.
The external `opencode-anthropic-auth` npm package is not installed — it was removed in
aidevops v2.90.0 when OpenCode v1.1.36 made it redundant.

After setup:

- **OpenCode v1.2.30+**: Run `opencode auth login` → select "Anthropic Pool" to add accounts
- **OpenCode v1.1.36–v1.2.29**: Run `opencode auth login` → select "Anthropic → Claude Pro/Max"
  (built-in), or use "Anthropic Pool" for multi-account rotation

### Recommended Configuration

For aidevops users:

- **Primary agent** (Build+): Use the aidevops OAuth pool for zero-cost API usage with rotation
- **Specialized agents**: Same authentication applies to all agents
- **CI/CD workflows**: Use manual API key method for GitHub Actions, etc.
- **Multiple accounts**: Add 2–3 Claude Pro/Max accounts to the pool for uninterrupted sessions

### Credential Storage

- **OAuth pool tokens**: `~/.aidevops/oauth-pool.json` (aidevops pool, 0600 permissions)
- **Built-in OAuth tokens** (v1.1.36–v1.2.29): `~/.config/opencode/auth.json`
- **API keys** (manual method): `~/.config/opencode/auth.json`
- **Environment variables**: Not used by OAuth methods

## Version History

### OpenCode Built-in Auth Timeline

- **OpenCode v1.2.30+**: Built-in `anthropic-auth` removed entirely. Use aidevops OAuth pool.
- **OpenCode v1.1.36–v1.2.29**: Built-in `anthropic-auth` included natively. External plugin not needed.
- **OpenCode pre-v1.1.36**: External `opencode-anthropic-auth` npm package required.

### External Plugin (`opencode-anthropic-auth` npm package)

- **0.0.9** (latest): Current version in repository
  - **DEPRECATED** — functionality built into OpenCode v1.1.36+, removed in v1.2.30
  - Maintained by Anomaly (anomalyco)
  - Dependencies: `@opencode-ai/plugin`, `@openauthjs/openauth`
- **0.0.8**: Updated dependencies and compatibility
  - Updated from `@openauthjs/openauth@^0.4.3` to latest
- **0.0.7**: Previous stable release
- **0.0.6**: Initial public release with core OAuth support
  - OAuth 2.0 with PKCE for Anthropic Console
  - Claude Pro/Max subscription support
  - Automatic token refresh

## References

- **Plugin Repository**: https://github.com/anomalyco/opencode-anthropic-auth
- **OpenCode Plugins**: https://opencode.ai/docs/plugins
- **Anthropic OAuth**: https://docs.anthropic.com/en/api/oauth
- **OpenAuth Library**: https://openauth.js.org/

## Related Documentation

- `tools/opencode/opencode-openai-auth.md` - OpenAI Pro pool (same architecture, ChatGPT Plus/Pro)
- `tools/opencode/opencode.md` - OpenCode integration overview
- `tools/ai-assistants/configuration.md` - AI assistant configuration
- `tools/credentials/api-key-management.md` - API key management
- `aidevops/setup.md` - Setup script details
