---
description: Feature worktree ref - new functionality
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Feature Worktree Ref

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Worktree ref prefix** | `feature/` |
| **Commit** | `feat: description` |
| **Version** | Minor bump (1.0.0 → 1.1.0) |
| **Create linked worktree from** | `main` |

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add feature/{description}
# e.g. feature/user-dashboard, feat: add user authentication
```

<!-- AI-CONTEXT-END -->

## When to Use

- New functionality or integrations
- Significant capability expansion

**Not for** bug fixes, refactors, or docs/config-only work.

## Guidance

- Minor-version bump applies when the branch ships user-visible capability, not internal-only maintenance.
- For implementation patterns, see `workflows/feature-development.md`.
