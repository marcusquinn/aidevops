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

- **Before building**: Check for existing WIP branch (`git branch -a | grep -E "(feature|bugfix|hotfix|refactor|chore|experiment)/"`)
- **Continue WIP**: `git checkout <branch>` and resume
- **New work**: Create branch from updated `main`, using type below

| Task Type | Branch Prefix | Subagent |
|-----------|---------------|----------|
| New functionality | `feature/` | `branch/feature.md` |
| Bug fix | `bugfix/` | `branch/bugfix.md` |
| Urgent production fix | `hotfix/` | `branch/hotfix.md` |
| Code restructure | `refactor/` | `branch/refactor.md` |
| Docs, deps, config | `chore/` | `branch/chore.md` |
| Spike, POC | `experiment/` | `branch/experiment.md` |
| Version release | `release/` | `branch/release.md` |

**Branch naming**: `{type}/{short-description}` — lowercase, hyphens, max ~50 chars (e.g., `feature/user-dashboard`, `bugfix/123-login-timeout`). Release branches use semver: `release/1.2.0`.

**Mandatory start**:

```bash
git checkout main && git pull origin main && git checkout -b {type}/{description}
```

**Task status**: Move task to `## In Progress`, add `started:` timestamp, then `beads-sync-helper.sh push`.

**Lifecycle**: Create → Develop → Preflight → Version → Push → PR → Review → Merge → Release → Postflight → Cleanup

**Task lifecycle**:

```text
Ready/Backlog → In Progress → In Review → Done
   (branch)       (develop)      (PR)     (merge/release)
```

<!-- AI-CONTEXT-END -->

**Before creating branches**: Read `workflows/git-workflow.md` for issue URL handling, fork detection, and new repo initialization.

**Branch names from planning files**: Slugify task descriptions — lowercase, spaces→hyphens, remove special chars. See `git-workflow.md` for full rules.

## Branch Lifecycle

| Stage | Action | Command / Agent | Required |
|-------|--------|-----------------|----------|
| 1. Create | Branch from `main` | `git checkout main && git pull origin main && git checkout -b {type}/{desc}` | Yes |
| 2. Develop | Conventional commits | `branch/{type}.md`, domain agents | Yes |
| 3. Preflight | Local quality checks | `.agents/scripts/linters-local.sh --fast` → `workflows/preflight.md` | Yes |
| 4. Version | Bump for releases | `.agents/scripts/version-manager.sh bump [major\|minor\|patch]` → `workflows/version-bump.md` | Releases only |
| 5. Push | Remote backup | `git push -u origin HEAD` | Yes |
| 6. PR | Create PR/MR | `gh pr create --fill` / `glab mr create --fill` → `workflows/pr.md` | Yes |
| 7. Review | Address feedback | `git add . && git commit -m "fix: ..." && git push` → `workflows/code-audit-remote.md` | Yes |
| 8. Merge | Squash merge | `gh pr merge --squash --delete-branch` | Yes |
| 9. Release | Tag and publish | `.agents/scripts/version-manager.sh release [major\|minor\|patch]` → `workflows/release.md` | Releases only |
| 10. Postflight | Verify CI/CD | `gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status` → `workflows/postflight.md` | Releases only |
| 11. Cleanup | Delete branch | `git branch -d {name}` / `git push origin --delete {name}` (if not auto-deleted) | Yes |

**Task status update on branch create**: Move task from `## Ready`/`## Backlog` to `## In Progress`, add `started:<ISO>`, then `beads-sync-helper.sh push`.

## Keeping Branch Updated

```bash
git checkout main && git pull origin main && git checkout your-branch && git merge main
# Resolve conflicts if any — see tools/git/conflict-resolution.md
```

## Safety: Protecting Uncommitted Work

Before destructive operations (reset, clean, rebase, checkout with changes):

```bash
git stash --include-untracked -m "safety: before [operation]"
# ... perform operation ...
git stash pop   # or: git stash show -p to review on conflict
```

`git restore` only recovers tracked files — untracked new files are permanently lost without stash.

## Commit Message Standards

```text
type: brief description

Detailed explanation if needed.
Fixes #123
```

Types: `feat:` `fix:` `refactor:` `docs:` `chore:` `test:`

## Related Workflows

- `workflows/git-workflow.md` — complete git workflow (issue URLs, fork detection, new repos)
- `workflows/pr.md` — PR creation and review
- `workflows/preflight.md` — quality checks before push
- `workflows/version-bump.md`, `workflows/changelog.md` — versioning
- `workflows/release.md`, `workflows/postflight.md` — release and verification
- `workflows/code-audit-remote.md` — code review
