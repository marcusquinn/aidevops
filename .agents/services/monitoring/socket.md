---
description: Socket dependency security scanning via MCP
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
mcp:
  - socket
---

# Socket MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Dependency security scanning for npm/pip packages
- **MCP**: Remote at `https://mcp.socket.dev/`
- **Auth**: API token from socket.dev
- **Credentials**: `~/.config/aidevops/credentials.sh` → `SOCKET_YOURNAME`
- **When to use**: Scan dependencies for vulnerabilities, malware, typosquatting, and package reputation before install

<!-- AI-CONTEXT-END -->

## MCP Setup

### 1. Create account

1. Sign up at [socket.dev](https://socket.dev)
2. Connect your GitHub account (optional, for repo scanning)

### 2. Generate API token

1. Go to Settings → API Tokens
2. Click "Create Token"
3. Select permissions (Full Access recommended for MCP)
4. Save the token:

```bash
echo 'export SOCKET_YOURNAME="sktsec_..."' >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

### 3. Configure OpenCode MCP

Socket uses the remote endpoint. Update your config:

```bash
jq '.mcp.socket = {"type": "remote", "url": "https://mcp.socket.dev/", "enabled": false}' \
  ~/.config/opencode/opencode.json > /tmp/oc.json && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

If API-token auth fails, the remote MCP may require a browser OAuth flow on first use.

### 4. Test Connection

```bash
source ~/.config/aidevops/credentials.sh
curl -s -H "Authorization: Bearer $SOCKET_YOURNAME" "https://api.socket.dev/v0/organizations" | jq '.organizations'
```

## Available MCP Tools

| Tool | Description |
|------|-------------|
| `scan_package` | Scan a specific package for issues |
| `scan_repo` | Scan a repository's dependencies |
| `get_package_info` | Get security info for a package |
| `list_issues` | List known issues in dependencies |

## Usage Examples

```text
@socket scan my package.json for vulnerabilities
@socket check if lodash@4.17.21 is safe
@socket what security issues are in this repo?
@socket is this package safe to install: some-new-package
```

## CLI Alternative

Use the Socket CLI directly when MCP is unavailable:

```bash
# Install
npm install -g @socketsecurity/cli

# Scan current project
socket scan

# Scan specific package
socket npm info lodash
```

## Troubleshooting

### "Unauthorized" error

1. Verify token: `source ~/.config/aidevops/credentials.sh && echo $SOCKET_YOURNAME`
2. Check token has correct permissions in socket.dev dashboard
3. Token format should start with `sktsec_`

### MCP not connecting

`mcp.socket.dev` may require browser OAuth instead of API-token auth. Start the MCP and complete the auth prompt if shown.

### Rate limits

Free tier requests are rate-limited. Upgrade if scans are throttled.

## Related

- [Socket Documentation](https://docs.socket.dev/)
- [Socket MCP](https://mcp.socket.dev/)
- [Socket CLI](https://github.com/SocketDev/socket-cli)
