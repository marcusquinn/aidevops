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
- **Credentials**: `~/.config/aidevops/mcp-env.sh` → `SENTRY_YOURNAME`

**When to use**:

- Debugging production errors
- Analyzing error trends and patterns
- Investigating specific issues or stack traces
- Checking release health and performance

<!-- AI-CONTEXT-END -->

## MCP Setup

### 1. Create Sentry Account & Organization

1. Sign up at [sentry.io](https://sentry.io)
2. **Create an organization first** (Settings → Organizations → Create)
3. Create a project within the organization

### 2. Generate Personal Auth Token

**Important**: Create the token AFTER creating the organization. Tokens created before the org don't inherit access.

1. Go to Settings → Account → Personal Tokens
2. Click "Create New Token"
3. Select permissions:
   - `alerts:read`, `alerts:write`
   - `event:admin`, `event:read`, `event:write`
   - `member:read`, `org:read`
   - `project:read`, `project:releases`
   - `team:read`

4. Save token:

```bash
echo 'export SENTRY_YOURNAME="sntryu_..."' >> ~/.config/aidevops/mcp-env.sh
chmod 600 ~/.config/aidevops/mcp-env.sh
```

### 3. Configure OpenCode MCP

```bash
source ~/.config/aidevops/mcp-env.sh
jq --arg token "$SENTRY_YOURNAME" \
  '.mcp.sentry = {"type": "local", "command": ["npx", "@sentry/mcp-server@latest", "--access-token", $token], "enabled": false}' \
  ~/.config/opencode/opencode.json > /tmp/oc.json && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

### 4. Test Connection

```bash
source ~/.config/aidevops/mcp-env.sh
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

For integrating Sentry into your app, use the wizard:

```bash
npx @sentry/wizard@latest -i nextjs  # Next.js
npx @sentry/wizard@latest -i node    # Node.js
npx @sentry/wizard@latest -i react   # React
```

The wizard creates all required config files. See [Sentry Docs](https://docs.sentry.io/) for platform-specific guides.

## Troubleshooting

### Token returns empty organizations

Create a new Personal Auth Token **after** the organization exists.

### "Not authenticated"

1. Verify token: `source ~/.config/aidevops/mcp-env.sh && echo $SENTRY_YOURNAME`
2. Test API: `curl -H "Authorization: Bearer $SENTRY_YOURNAME" https://sentry.io/api/0/`
3. Restart OpenCode after config changes

### Org token vs Personal token

- **Org tokens** (`org:ci` scope) - Limited, for CI/CD only
- **Personal tokens** - Full access, use these for MCP

## Related

- [Sentry Documentation](https://docs.sentry.io/)
- [Sentry MCP](https://mcp.sentry.dev/)
