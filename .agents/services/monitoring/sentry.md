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

1. Sign up at [sentry.io](https://sentry.io), create an organization (`Settings → Organizations → Create`), then create a project inside it.
2. Generate a **personal** auth token at `Settings → Account → Personal Tokens → Create New Token` — create it **after** the org exists; earlier tokens may not inherit org access.
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

`list_projects` · `get_issue` · `list_issues` · `get_event` · `resolve_issue` · `assign_issue`

## Usage Examples

```text
@sentry list my projects
@sentry show recent issues in my-project
@sentry get details for issue PROJ-123
@sentry what's the error rate for the latest release?
```

## SDK Integration

```bash
npx @sentry/wizard@latest -i nextjs
npx @sentry/wizard@latest -i node
npx @sentry/wizard@latest -i react
```

The wizard creates the required config files. See [Sentry Docs](https://docs.sentry.io/) for platform-specific guides. Keep `sendDefaultPii` disabled unless you explicitly need user/IP metadata and have privacy coverage.

## Troubleshooting

- **Empty organizations**: create a new token **after** the organization exists.
- **`Not authenticated`**: verify the variable (`source ~/.config/aidevops/credentials.sh && printenv | grep '^SENTRY_YOURNAME$'`), test the API (`curl -H "Authorization: Bearer $SENTRY_YOURNAME" https://sentry.io/api/0/`), then restart the runtime.
- **Wrong token type**: org tokens (`org:ci`) are for CI/CD; MCP needs a personal token.

## Related

- [Sentry Documentation](https://docs.sentry.io/) · [Sentry MCP](https://mcp.sentry.dev/)
- `services/monitoring/langwatch.md` · `services/monitoring/socket.md`
