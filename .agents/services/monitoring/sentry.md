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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Sentry MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Production error debugging, trend analysis, stack trace investigation, release health
- **MCP**: Local stdio mode with `@sentry/mcp-server`
- **Auth**: Personal Auth Token (created **after** org exists — earlier tokens may not inherit org access)
- **Credentials**: `~/.config/aidevops/credentials.sh` → `SENTRY_YOURNAME`
- **MCP tools**: `list_projects` · `get_issue` · `list_issues` · `get_event` · `resolve_issue` · `assign_issue`
- **Use instead**: LLM traces/evals → `services/monitoring/langwatch.md`; dependency security → `services/monitoring/socket.md`

<!-- AI-CONTEXT-END -->

## MCP Setup

1. Sign up at [sentry.io](https://sentry.io), create an org (`Settings → Organizations → Create`), then a project.
2. Generate a **personal** auth token (`Settings → Account → Personal Tokens → Create New Token`). Required scopes: `alerts:read`, `alerts:write`, `event:admin`, `event:read`, `event:write`, `member:read`, `org:read`, `project:read`, `project:releases`, `team:read`
3. Save the token:

```bash
echo 'export SENTRY_YOURNAME="sntryu_..."' >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

4. Configure MCP in `~/.config/opencode/opencode.json` or equivalent:

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

5. Test:

```bash
source ~/.config/aidevops/credentials.sh
curl -s -H "Authorization: Bearer $SENTRY_YOURNAME" "https://sentry.io/api/0/organizations/" | jq '.[].slug'
```

## Usage Examples

```text
@sentry list my projects
@sentry show recent issues in my-project
@sentry get details for issue PROJ-123
@sentry what's the error rate for the latest release?
```

## SDK Integration

```bash
npx @sentry/wizard@latest -i nextjs   # also: node, react
```

Keep `sendDefaultPii` disabled unless you explicitly need user/IP metadata and have privacy coverage. See [Sentry Docs](https://docs.sentry.io/) for platform-specific guides.

## Troubleshooting

- **Empty organizations**: token created before org existed — generate a new one after org creation.
- **`Not authenticated`**: verify (`source ~/.config/aidevops/credentials.sh && printenv | grep '^SENTRY_YOURNAME$'`), test API (`curl -H "Authorization: Bearer $SENTRY_YOURNAME" https://sentry.io/api/0/`), restart runtime.
- **Wrong token type**: org tokens (`org:ci`) are for CI/CD; MCP needs a personal token.

## Related

- [Sentry Documentation](https://docs.sentry.io/) · [Sentry MCP](https://mcp.sentry.dev/)
- `services/monitoring/langwatch.md` · `services/monitoring/socket.md`
