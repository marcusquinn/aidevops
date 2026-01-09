---
description: Anthropic OAuth authentication plugin for OpenCode
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
---

# OpenCode Anthropic Auth Plugin

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: OAuth authentication for Claude Pro/Max accounts in OpenCode
- **Repository**: https://github.com/anomalyco/opencode-anthropic-auth
- **Installation**: `npm install -g opencode-anthropic-auth` (auto-installed by setup.sh)
- **Alternative to**: Manual API key management, requires Claude subscription

**Authentication Methods**:

| Method | Use Case | Requirements |
|--------|----------|--------------|
| **Claude Pro/Max OAuth** | Free API usage for subscribers | Active Claude Pro/Max subscription |
| **Create API Key** | Traditional API key via OAuth | Anthropic Console access |
| **Manual API Key** | Existing API keys | API key from console.anthropic.com |

**Quick Setup**:

```bash
# Install plugin (auto-installed by aidevops setup.sh)
npm install -g opencode-anthropic-auth

# Authenticate in OpenCode
opencode auth login
# Select: Anthropic → Claude Pro/Max (or Create an API Key)
# Follow OAuth flow in browser
```

<!-- AI-CONTEXT-END -->

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

### Automatic Installation (Recommended)

The aidevops `setup.sh` script automatically installs this plugin:

```bash
cd ~/Git/aidevops
./setup.sh
```

This installs the plugin globally and configures OpenCode to use it.

### Manual Installation

```bash
# Install via npm
npm install -g opencode-anthropic-auth

# Plugin is automatically discovered by OpenCode
```

## Authentication Methods

### 1. Claude Pro/Max OAuth (Recommended for Subscribers)

Best for users with active Claude Pro or Max subscriptions who want free API usage.

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

### OpenCode Detection

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

```bash
# First-time setup
opencode auth login

# Select Anthropic → Claude Pro/Max
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
opencode run "Hello, Claude!" --model anthropic/claude-sonnet-4-20250514
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

### Plugin Not Detected

**Symptoms**: Anthropic OAuth options not shown in `opencode auth login`.

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

| Feature | Anthropic OAuth (this plugin) | Antigravity OAuth | Manual API Key |
|---------|-------------------------------|-------------------|----------------|
| **Claude Pro/Max cost** | $0 (subscription) | N/A | Standard rates |
| **Google OAuth** | No | Yes | No |
| **Multi-account rotation** | No | Yes | No |
| **Auto token refresh** | Yes | Yes | N/A |
| **Beta features** | Auto-enabled | Manual | Manual |
| **Setup complexity** | Low (OAuth flow) | Low (OAuth flow) | Lowest (paste key) |
| **Best for** | Claude subscribers | Gemini/Claude users | API-only users |

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

For teams or multi-account scenarios:

1. **Different users**: Each user authenticates with their own account
2. **Account switching**: Use `opencode auth logout && opencode auth login`
3. **Organization accounts**: Ensure organization members have API access enabled

**Note**: Unlike Antigravity, this plugin does not support automatic multi-account load balancing. Use separate OpenCode profiles or environments for true multi-account rotation.

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
DEBUG=opencode:* opencode run "test" --model anthropic/claude-sonnet-4-20250514

# Check token expiration
cat ~/.config/opencode/auth.json | jq '.anthropic'

# Monitor API requests (requires network inspection tools)
# Use browser DevTools on OAuth flow to inspect requests
```

## Integration with aidevops

### Automatic Setup

The aidevops `setup.sh` installs and configures this plugin:

```bash
cd ~/Git/aidevops
./setup.sh
```

After setup:
1. Plugin is installed globally via npm
2. OpenCode automatically discovers it
3. Authentication is ready to use with `opencode auth login`

### Recommended Configuration

For aidevops users:

- **Primary agent** (Build+): Use Claude Pro/Max OAuth for zero-cost API usage
- **Specialized agents**: Same authentication applies to all agents
- **CI/CD workflows**: Use manual API key method for GitHub Actions, etc.

### Credential Storage

aidevops follows OpenCode's credential storage:

- OAuth tokens: `~/.config/opencode/auth.json`
- API keys (if using manual method): Same location
- Environment variables: Not used by this plugin (OAuth tokens only)

## Version History

- **0.0.8** (latest): Current version in repository
- Maintained by Anomaly (anomalyco)
- Dependencies: `@opencode-ai/plugin`, `@openauthjs/openauth`

## References

- **Plugin Repository**: https://github.com/anomalyco/opencode-anthropic-auth
- **OpenCode Plugins**: https://opencode.ai/docs/plugins
- **Anthropic OAuth**: https://docs.anthropic.com/en/api/oauth
- **OpenAuth Library**: https://openauth.js.org/

## Related Documentation

- `tools/opencode/opencode.md` - OpenCode integration overview (includes Antigravity)
- `tools/ai-assistants/configuration.md` - AI assistant configuration
- `tools/credentials/api-key-management.md` - API key management
- `aidevops/setup.md` - Setup script details
