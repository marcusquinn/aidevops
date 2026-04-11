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
  socket_*: true
  # TODO(permission-migration): Replace with permission: socket: allow
  # once anomalyco/opencode#6892 is resolved.
mcp:
  - socket
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Socket MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Dependency security scanning for npm/pip packages
- **MCP**: Remote at `https://mcp.socket.dev/`
- **Auth**: API token from socket.dev
- **Credentials**: `~/.config/aidevops/credentials.sh` → `SOCKET_YOURNAME`
- **Use for**: Vulnerability scans, malware/typosquat checks, and package reputation review before install

<!-- AI-CONTEXT-END -->

## Setup

1. Sign up at [socket.dev](https://socket.dev). GitHub connection is optional for repo scans.
2. Create an API token in Settings → API Tokens. Grant Full Access if available.
3. Save the token:

```bash
echo 'export SOCKET_YOURNAME="sktsec_..."' >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

4. Configure OpenCode MCP. Socket uses the remote endpoint:

```bash
jq '.mcp.socket = {"type": "remote", "url": "https://mcp.socket.dev/", "enabled": false}' \
  ~/.config/opencode/opencode.json > /tmp/oc.json && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

5. If API-token auth fails, complete the browser OAuth flow on first use.
6. Test the token:

```bash
source ~/.config/aidevops/credentials.sh
curl -s -H "Authorization: Bearer $SOCKET_YOURNAME" "https://api.socket.dev/v0/organizations" | jq '.organizations'
```

## MCP Tools

- `scan_package` — scan a package for issues
- `scan_repo` — scan repository dependencies
- `get_package_info` — fetch package security data
- `list_issues` — list known dependency issues

## Example prompts

```text
@socket scan my package.json for vulnerabilities
@socket check if lodash@4.17.21 is safe
@socket what security issues are in this repo?
@socket is this package safe to install: some-new-package
```

## CLI fallback

Use the Socket CLI when MCP is unavailable:

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

- Verify the token is set: `source ~/.config/aidevops/credentials.sh && echo $SOCKET_YOURNAME`
- Check token permissions in the socket.dev dashboard
- Confirm the token starts with `sktsec_`

### MCP not connecting

- `mcp.socket.dev` may require browser OAuth instead of API-token auth
- Start the MCP and complete the prompt if shown

### Rate limits

- Free tier requests are rate-limited; upgrade if scans are throttled

## Related

- [Socket Documentation](https://docs.socket.dev/)
- [Socket MCP](https://mcp.socket.dev/)
- [Socket CLI](https://github.com/SocketDev/socket-cli)
