---
description: LocalWP database access - read-only SQL queries, schema inspection via MCP. Requires LocalWP running
mode: subagent
temperature: 0.1
tools:
  bash: true
  read: true
  localwp_*: true
  # TODO(permission-migration): Replace with permission: localwp: allow
  # once anomalyco/opencode#6892 is resolved.
  task: true
mcp:
  - localwp
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# LocalWP Database Access Subagent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: AI read-only access to Local by Flywheel WordPress databases
- **Install**: `npm install -g @verygoodplugins/mcp-local-wp`
- **Start**: `./.agents/scripts/localhost-helper.sh start-mcp`
- **Port**: 8085 (default)

**MCP Tools**:

- `mysql_query` - Execute SELECT/SHOW/DESCRIBE/EXPLAIN queries
- `mysql_schema` - List tables or inspect specific table structure

**Example Queries**:

```sql
SELECT ID, post_title FROM wp_posts WHERE post_status='publish' LIMIT 5;
DESCRIBE wp_postmeta;
```

**Requires**: Local by Flywheel running with active site
**Security**: Read-only only, local development environments only

**Typically invoked from**: `@wp-dev` for database inspection during debugging

<!-- AI-CONTEXT-END -->

## Installation

**Prerequisites**: Local by Flywheel installed and running, Node.js 18+, at least one active Local site.

```bash
npm install -g @verygoodplugins/mcp-local-wp
mcp-local-wp --help
```

## MCP Configuration

Add to your MCP config (`Claude.json`, `opencode.json`, or equivalent):

```json
{
  "mcpServers": {
    "localwp": {
      "command": "mcp-local-wp",
      "args": ["--transport", "sse", "--port", "8085"],
      "env": {
        "DEBUG": "false"
      }
    }
  }
}
```

Omit `env` block if debug logging not needed.

### Framework Helper

```bash
./.agents/scripts/localhost-helper.sh start-mcp   # Start MCP server
./.agents/scripts/localhost-helper.sh stop-mcp    # Stop MCP server
./.agents/scripts/localhost-helper.sh list-localwp # List LocalWP sites
```

## Available Tools

### mysql_query

Read-only SQL: `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN`. Parameterized queries supported.

```sql
-- Recent published posts
SELECT ID, post_title, post_date, post_status
FROM wp_posts
WHERE post_type = 'post' AND post_status = 'publish'
ORDER BY post_date DESC LIMIT 5;

-- Parameterized (params: ["publish", "5"])
SELECT * FROM wp_posts WHERE post_status = ? ORDER BY post_date DESC LIMIT ?;
```

### mysql_schema

```bash
mysql_schema()            # List all tables
mysql_schema("wp_posts")  # Inspect specific table
```

## Example Queries

### Plugin Development (LearnDash)

```sql
DESCRIBE wp_learndash_user_activity;

SELECT ua.*, uam.activity_meta_key, uam.activity_meta_value
FROM wp_learndash_user_activity ua
LEFT JOIN wp_learndash_user_activity_meta uam ON ua.activity_id = uam.activity_id
WHERE ua.activity_type = 'quiz' AND ua.user_id = 123;
```

### WooCommerce Orders

```sql
SELECT p.ID, p.post_date, pm.meta_key, pm.meta_value
FROM wp_posts p
JOIN wp_postmeta pm ON p.ID = pm.post_id
WHERE p.post_type = 'shop_order'
AND pm.meta_key IN ('_order_total', '_billing_email')
ORDER BY p.post_date DESC LIMIT 10;
```

### User Capabilities

```sql
SELECT u.user_login, u.user_email, um.meta_value as capabilities
FROM wp_users u
JOIN wp_usermeta um ON u.ID = um.user_id
WHERE um.meta_key = 'wp_capabilities'
AND um.meta_value LIKE '%administrator%';
```

### Custom Fields

```sql
SELECT p.post_title, pm.meta_key, pm.meta_value
FROM wp_posts p
JOIN wp_postmeta pm ON p.ID = pm.post_id
WHERE p.post_status = 'publish'
AND pm.meta_key = '_featured_image'
ORDER BY p.post_date DESC;
```

## How It Works

The MCP server auto-detects your active Local by Flywheel MySQL instance:

1. **Process Detection**: Scans running processes for active mysqld instances
2. **Config Parsing**: Extracts MySQL config from the active Local site
3. **Dynamic Connection**: Connects using the correct socket path
4. **Fallback**: Falls back to environment variables for custom setups

Local directory structure:

```text
~/Library/Application Support/Local/run/
├── lx97vbzE7/                    # Dynamic site ID (changes on restart)
│   ├── conf/mysql/my.cnf        # MySQL configuration
│   └── mysql/mysqld.sock        # Socket connection
└── WP7lolWDi/                   # Another site
    ├── conf/mysql/my.cnf
    └── mysql/mysqld.sock
```

## Security

- **Read-only**: Only SELECT/SHOW/DESCRIBE/EXPLAIN allowed
- **Single statement**: Multiple statements blocked
- **Local only**: Designed for local development environments
- **No external connections**: Prioritizes Unix socket connections
- **Process isolation**: Runs in separate process from applications

## Troubleshooting

| Error | Fix |
|-------|-----|
| "No active MySQL process found" | Ensure LocalWP is running with at least one started site |
| "MySQL socket not found" | Verify site is fully started; try stop/restart in Local |
| "Connection refused" | Check MySQL service is running; check for port conflicts; restart LocalWP |

### Debug Mode

```bash
DEBUG=mcp-local-wp ./.agents/scripts/localhost-helper.sh start-mcp
```

## Related Subagents

| Task | Subagent | Reason |
|------|----------|--------|
| Development and debugging | `@wp-dev` | This subagent is typically called from @wp-dev |
| Content management | `@wp-admin` | Admin tasks, not database-level |
| Fleet management | `@mainwp` | Multi-site operations |

## Related Documentation

| Topic | File |
|-------|------|
| WordPress development | `workflows/wp-dev.md` |
| WordPress admin | `workflows/wp-admin.md` |
| Local development | `localhost.md` |
| MCP setup | `context7-mcp-setup.md` |
