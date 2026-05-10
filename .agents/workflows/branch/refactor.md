---
description: Refactor worktree ref - code restructure, same behavior
mode: subagent
tools:
  read: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Refactor Worktree Ref

| Aspect | Value |
|--------|-------|
| **Worktree ref prefix** | `refactor/` |
| **Commit** | `refactor: description` |
| **Version** | Usually none (no behavior change) |
| **Create linked worktree from** | `main` |

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add refactor/{description}
# Then cd into the sibling worktree path printed by the helper before editing.
```

## When to Use

- Code restructuring without behavior change
- Extracting reusable components, reducing technical debt
- Performance improvements (same behavior, faster)

**Not for**: Bug fixes (`bugfix/`) or new features (`feature/`).

**Golden rule: Same inputs → Same outputs.** If behavior changes: split into `bugfix/`/`feature/` or document the intentional change.

## Testing & Review

All existing tests must pass before and after:

```bash
npm test  # or project-specific test command
```

**PR reviewers verify:** no behavior changes (unless documented), tests pass, no performance regression.

## Examples

```bash
# Branch names
refactor/extract-auth-service
refactor/simplify-database-layer
refactor/consolidate-api-handlers

# Commit message
refactor: extract authentication into dedicated service

- Move auth logic from UserController to AuthService
- No behavior changes; all existing tests pass
```
