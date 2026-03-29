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
- **MCP**: Local stdio mode with `@sentry/mcp-server`
- **Auth**: Personal Auth Token (created after org exists)
- **Credentials**: `~/.config/aidevops/credentials.sh` → `SENTRY_YOURNAME`
- **When to use**: Production error debugging, error trend analysis, stack trace investigation, release health checks

<!-- AI-CONTEXT-END -->

## MCP Setup

### 1. Create Sentry Account & Organization

1. Sign up at [sentry.io](https://sentry.io)
2. Create an organization first (Settings → Organizations → Create)
3. Create a project within the organization

### 2. Generate Personal Auth Token

Create the token **after** creating the organization — tokens created before the org don't inherit access.

1. Settings → Account → Personal Tokens → Create New Token
2. Required permissions: `alerts:read`, `alerts:write`, `event:admin`, `event:read`, `event:write`, `member:read`, `org:read`, `project:read`, `project:releases`, `team:read`
3. Save token:

```bash
echo 'export SENTRY_YOURNAME="sntryu_..."' >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

### 3. Configure MCP

Add to your MCP config (`~/.config/opencode/opencode.json` or equivalent):

```json
{
  "mcpServers": {
    "sentry": {
      "command": "npx",
      "args": ["@sentry/mcp-server@latest", "--access-token", "${SENTRY_YOURNAME}"],
      "enabled": true
    }
  }
}
```

Or programmatically:

```bash
source ~/.config/aidevops/credentials.sh
tmp_json="$(mktemp)"
jq --arg token "$SENTRY_YOURNAME" \
  '.mcpServers.sentry = {"command": "npx", "args": ["@sentry/mcp-server@latest", "--access-token", $token], "enabled": true}' \
  ~/.config/opencode/opencode.json > "$tmp_json" && mv "$tmp_json" ~/.config/opencode/opencode.json
```

### 4. Test Connection

```bash
source ~/.config/aidevops/credentials.sh
curl -s -H "Authorization: Bearer $SENTRY_YOURNAME" "https://sentry.io/api/0/organizations/" | jq '.[].slug'
```

## Available MCP Tools

| Tool | Description |
|------|-------------|
| `list_projects` | List all Sentry projects |
| `get_issue` | Get details of a specific issue |
| `list_issues` | List issues for a project |
| `get_event` | Get details of a specific event |
| `resolve_issue` | Mark an issue as resolved |
| `assign_issue` | Assign issue to a team member |

## Usage Examples

```text
@sentry list my projects
@sentry show recent issues in my-project
@sentry get details for issue PROJ-123
@sentry what's the error rate for the latest release?
```

## SDK Integration

```bash
npx @sentry/wizard@latest -i nextjs  # Next.js
npx @sentry/wizard@latest -i node    # Node.js
npx @sentry/wizard@latest -i react   # React
```

The wizard creates all required config files. See [Sentry Docs](https://docs.sentry.io/) for platform-specific guides. Keep `sendDefaultPii` disabled unless you need user/IP metadata and have privacy coverage.

## Troubleshooting

**Token returns empty organizations**: Create a new token **after** the organization exists.

**"Not authenticated"**:
1. Verify key exists: `source ~/.config/aidevops/credentials.sh && printenv | cut -d= -f1 | grep '^SENTRY_YOURNAME$'`
2. Test API: `curl -H "Authorization: Bearer $SENTRY_YOURNAME" https://sentry.io/api/0/`
3. Restart your runtime after config changes

**Org token vs Personal token**: Org tokens (`org:ci` scope) are CI/CD-only. Use personal tokens for MCP.

## Related

- [Sentry Documentation](https://docs.sentry.io/)
- [Sentry MCP](https://mcp.sentry.dev/)
