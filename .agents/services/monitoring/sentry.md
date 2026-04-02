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
- **When to use**: Production error debugging, trend analysis, stack trace investigation, release health checks
- **Use something else for**: LLM traces/evals → `services/monitoring/langwatch.md`; dependency security → `services/monitoring/socket.md`

<!-- AI-CONTEXT-END -->

## MCP Setup

1. Create the account structure first:
   - Sign up at [sentry.io](https://sentry.io)
   - Create the organization (`Settings → Organizations → Create`)
   - Create a project inside that organization
2. Generate a **personal** auth token at `Settings → Account → Personal Tokens → Create New Token`
   - Create the token **after** the organization exists; earlier tokens may not inherit org access
   - Required scopes: `alerts:read`, `alerts:write`, `event:admin`, `event:read`, `event:write`, `member:read`, `org:read`, `project:read`, `project:releases`, `team:read`
3. Save the token:

```bash
echo 'export SENTRY_YOURNAME="sntryu_..."' >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

4. Configure the MCP in `~/.config/opencode/opencode.json` or equivalent:

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

5. Test the token:

```bash
source ~/.config/aidevops/credentials.sh
curl -s -H "Authorization: Bearer $SENTRY_YOURNAME" "https://sentry.io/api/0/organizations/" | jq '.[].slug'
```

## Available MCP Tools

- `list_projects` — list Sentry projects
- `get_issue` — fetch one issue
- `list_issues` — list project issues
- `get_event` — fetch one event
- `resolve_issue` — mark an issue resolved
- `assign_issue` — assign an issue

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

The wizard creates the required config files. See [Sentry Docs](https://docs.sentry.io/) for platform-specific guides. Keep `sendDefaultPii` disabled unless you explicitly need user/IP metadata and have privacy coverage.

## Troubleshooting

- **Empty organizations**: create a new token **after** the organization exists.
- **`Not authenticated`**:
  1. Verify the variable exists: `source ~/.config/aidevops/credentials.sh && printenv | cut -d= -f1 | grep '^SENTRY_YOURNAME$'`
  2. Test the API directly: `curl -H "Authorization: Bearer $SENTRY_YOURNAME" https://sentry.io/api/0/`
  3. Restart the runtime after config changes
- **Wrong token type**: org tokens (`org:ci`) are for CI/CD; MCP needs a personal token.

## Related

- [Sentry Documentation](https://docs.sentry.io/)
- [Sentry MCP](https://mcp.sentry.dev/)
- `services/monitoring/langwatch.md`
- `services/monitoring/socket.md`
