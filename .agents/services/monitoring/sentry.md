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
  sentry_*: true
  # TODO(permission-migration): Replace with permission: sentry: allow
  # once anomalyco/opencode#6892 is resolved.
mcp:
  - sentry
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Sentry MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Production error debugging, trend analysis, stack trace investigation, release health
- **MCP**: Sentry's hosted remote server, `https://mcp.sentry.dev/mcp` (registry entry `sentry`, `type: remote`), connected on demand from this agent with `aidevops_mcp connect sentry`
- **Auth**: OAuth via OpenCode (`opencode mcp auth sentry`); no token in `credentials.sh` or `opencode.json`
- **Check**: `sentry_whoami` confirms the connected account
- **Use instead**: LLM traces/evals → `services/monitoring/langwatch.md`; dependency security → `services/monitoring/socket.md`

<!-- AI-CONTEXT-END -->

## MCP Setup

1. Sign up at [sentry.io](https://sentry.io) and create an org and a project.
2. From the `sentry` agent, run `aidevops_mcp connect sentry`.
3. If it reports that an OAuth login is needed, run the printed command in a terminal, approve in the browser, then connect again. No restart is needed.

aidevops launches OpenCode with a per-project `XDG_DATA_HOME`, so each session reads its own `opencode/mcp-auth.json`. The printed command targets that store:

```bash
XDG_DATA_HOME="<session data dir>" opencode mcp auth sentry
```

A plain `opencode mcp auth sentry` writes the global store (`~/.local/share/opencode/mcp-auth.json`). Newly launched sessions merge its entries into their own store without overwriting entries the session already has (GH#40451); sessions that are already running need the session-store command.

The registry replaces any legacy local `@sentry/mcp-server` + access-token entry in `opencode.json`. Remove that entry's token from your config.

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

- **Connect reports `needs_auth`**: run the printed `opencode mcp auth sentry` command for the session store, then connect again.
- **Logged in, but the session still says not authenticated**: the login went to a different store. Compare `opencode mcp auth list` in the session shell with a normal terminal, then log in with the session's `XDG_DATA_HOME`.
- **`needs_client_registration`**: OpenCode could not register an OAuth client automatically; retry `opencode mcp auth sentry` and check the OpenCode MCP docs.
- **Diagnosis**: `mcp-diagnose.sh sentry` reports `[remote]` and the login command; it never suggests a local install.

## Related

- [Sentry Documentation](https://docs.sentry.io/) · [Sentry MCP](https://mcp.sentry.dev/)
- `services/monitoring/langwatch.md` · `services/monitoring/socket.md`
