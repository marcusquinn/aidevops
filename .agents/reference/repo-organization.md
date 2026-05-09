<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Repository Organization

Keep canonical clones and their linked worktrees grouped by product/ecosystem under `~/Git/`.

## Default clone locations

| Repo type | Default parent |
|-----------|----------------|
| WordPress plugins/themes/tools | `~/Git/wordpress/` |
| EspoCRM extensions/addons/tools | `~/Git/espocrm/` |
| MCP servers/clients/adapters | `~/Git/mcp/` |
| Other standalone products/sites/tools | `~/Git/` |

Examples:

```bash
gh repo clone owner/wp-plugin ~/Git/wordpress/wp-plugin
gh repo clone owner/espo-addon ~/Git/espocrm/espo-addon
gh repo clone owner/example-mcp ~/Git/mcp/example-mcp
```

## Worktrees

Create worktrees as siblings of their canonical clone, in the same grouped parent. `worktree-helper.sh add <branch>` already does this because it derives the path from the canonical repo's parent directory.

Examples:

| Canonical clone | Auto worktree parent |
|-----------------|----------------------|
| `~/Git/wordpress/wp-performance-action` | `~/Git/wordpress/` |
| `~/Git/espocrm/example-extension` | `~/Git/espocrm/` |
| `~/Git/mcp/example-server` | `~/Git/mcp/` |

If a clone was accidentally created at `~/Git/{repo}` but belongs to a grouped ecosystem, move or recreate it under the grouped parent before adding new worktrees. Do not overwrite an existing grouped clone; fetch the required remotes/branches into the grouped canonical repo and recreate clean linked worktrees there.

## Related

- `workflows/worktree.md` — worktree mechanics
- `workflows/git-workflow.md` — issue/PR flow
- `tools/wordpress/wp-dev.md` — WordPress-specific layout
