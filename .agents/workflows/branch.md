---
description: Git branch creation and management workflow
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Resume**: `wt list` (git worktree list)
- **Start**: `wt switch -c {type}/{name}` (from canonical repo on `main`)
- **Fallback**: `worktree-helper.sh add {type}/{name}`
- **Isolation**: Keep `~/Git/{repo}/` on `main`; work in linked worktree paths.

| Type | Prefix | Subagent |
|------|--------|----------|
| Feature | `feature/` | `branch/feature.md` |
| Bugfix | `bugfix/` | `branch/bugfix.md` |
| Hotfix | `hotfix/` | `branch/hotfix.md` |
| Refactor | `refactor/` | `branch/refactor.md` |
| Chore | `chore/` | `branch/chore.md` |
| Experiment | `experiment/` | `branch/experiment.md` |
| Release | `release/` | `branch/release.md` |

- **Naming**: `{type}/{short-desc}` (lowercase, hyphenated, ~50 chars). Example: `feature/user-dashboard`.
- **Tasks**: Move to `## In Progress`, add `started:<ISO>`, then `beads-sync-helper.sh push`.

<!-- AI-CONTEXT-END -->

## Branch Lifecycle

| Stage | Command / Agent | Notes |
|-------|-----------------|-------|
| Create | `wt switch -c {type}/{desc}` | Create linked worktree from `main` |
| Develop | `branch/{type}.md` | Use conventional commits |
| Preflight | `linters-local.sh --fast` | Required before push; see `workflows/preflight.md` |
| Version | `version-manager.sh bump` | Releases only; see `workflows/version-bump.md` |
| Push | `git push -u origin HEAD` | Remote backup |
| PR | `gh pr create --fill` | Required; see `workflows/pr.md` |
| Review | `git push` | Address feedback; see `workflows/code-audit-remote.md` |
| Merge | `gh pr merge --squash` | Required |
| Release | `version-manager.sh release` | Releases only; see `workflows/release.md` |
| Postflight | `gh run watch` | Releases only; see `workflows/postflight.md` |
| Cleanup | `worktree-helper.sh remove` | Remove worktree; delete branch if needed |

## Worktree Rules

- **Inheritance**: Canonical repo must stay on `main` for the next session.
- **Context**: Reference worktree paths (`~/Git/{repo}-{type}-{slug}/`), not "branch switching".
- **Freshness**: Re-read files at worktree path after switching before editing.
- **Ownership**: Never remove worktrees you didn't create without explicit request.
- **Slugification**: Paths are slugified (converts `/` to `-`, lowercases). Pre-slugify task descriptions for exact path control.

## Safety & Maintenance

### Protecting Uncommitted Work

Stash before reset, clean, rebase, or checkout:

```bash
git stash --include-untracked -m "safety: before [operation]"
# ... perform operation ...
git stash pop   # Use 'git stash show -p' to review on conflict
```

*Note: `git restore` only recovers tracked files; untracked files require stashing.*

### Keeping Branch Updated

```bash
git fetch origin main && git merge origin/main
# Resolve conflicts using tools/git/conflict-resolution.md
```

## Standards & References

- **Commits**: Conventional (`feat:`, `fix:`, etc.). Include issue refs if required.
- **Core Rules**: `workflows/git-workflow.md` (issue URLs, fork detection, PR rules).
- **Worktrees**: `workflows/worktree.md` (creation, ownership, cleanup).
- **Releases**: `workflows/changelog.md`, `workflows/postflight.md`.
