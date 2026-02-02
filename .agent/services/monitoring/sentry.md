---
description: Sentry error monitoring and debugging via MCP
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
  - sentry
---

# Sentry MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Error monitoring, debugging, and issue tracking via Sentry
- **MCP**: Remote at `https://mcp.sentry.dev/mcp`
- **Auth**: OAuth flow (browser-based) or API token
- **Credentials**: `~/.config/aidevops/mcp-env.sh` → `SENTRY_MARCUSQUINN`

**When to use**:

- Debugging production errors
- Analyzing error trends and patterns
- Investigating specific issues or stack traces
- Checking release health and performance

**OpenCode Config** (`~/.config/opencode/opencode.json`):

```json
"sentry": {
  "type": "remote",
  "url": "https://mcp.sentry.dev/mcp",
  "enabled": true
}
```

<!-- AI-CONTEXT-END -->

## Setup

### 1. Create Sentry Account

Sign up at [sentry.io](https://sentry.io) if you don't have an account.

### 2. Generate Auth Token

1. Go to Settings → Auth Tokens
2. Create new token with permissions:
   - `alerts:read`, `alerts:write`
   - `event:admin`, `event:read`, `event:write`
   - `member:read`, `org:read`
   - `project:read`, `project:releases`
   - `team:read`

3. Save token:

```bash
echo 'export SENTRY_YOURNAME="sntryu_..."' >> ~/.config/aidevops/mcp-env.sh
chmod 600 ~/.config/aidevops/mcp-env.sh
```

### 3. Enable MCP

The Sentry MCP uses OAuth flow. When you first use it:

1. OpenCode will prompt for authentication
2. Browser opens to Sentry OAuth page
3. Authorize the connection
4. Token is cached for future sessions

## Available Tools

The Sentry MCP provides tools for:

| Tool | Description |
|------|-------------|
| `list_projects` | List all Sentry projects |
| `get_issue` | Get details of a specific issue |
| `list_issues` | List issues for a project |
| `get_event` | Get details of a specific event |
| `resolve_issue` | Mark an issue as resolved |
| `assign_issue` | Assign issue to a team member |

## Usage Examples

### List Recent Issues

```text
Show me the 10 most recent unresolved issues in the main project
```

### Investigate an Error

```text
Get details for issue PROJ-123 including the stack trace
```

### Check Release Health

```text
What's the error rate for the latest release?
```

## Troubleshooting

### "Not authenticated"

Re-authenticate by:

1. Clear cached OAuth token
2. Restart OpenCode
3. Use a Sentry tool - it will prompt for auth

### "Project not found"

Verify you have access to the project in Sentry's web UI.

## Related

- [Sentry Documentation](https://docs.sentry.io/)
- [Sentry MCP](https://mcp.sentry.dev/)
