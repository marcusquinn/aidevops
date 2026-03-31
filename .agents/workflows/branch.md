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

- **Resume first**: `git branch -a | rg "(feature|bugfix|hotfix|refactor|chore|experiment)/"`
- **Continue WIP**: `git checkout <branch>`
- **New work**: branch from updated `main`

| Task Type | Branch Prefix | Subagent |
|-----------|---------------|----------|
| New functionality | `feature/` | `branch/feature.md` |
| Bug fix | `bugfix/` | `branch/bugfix.md` |
| Urgent production fix | `hotfix/` | `branch/hotfix.md` |
| Code restructure | `refactor/` | `branch/refactor.md` |
| Docs, deps, config | `chore/` | `branch/chore.md` |
| Spike, POC | `experiment/` | `branch/experiment.md` |
| Version release | `release/` | `branch/release.md` |

**Branch naming**: `{type}/{short-description}` — lowercase, hyphenated, ~50 chars max. Example: `feature/user-dashboard`, `bugfix/123-login-timeout`; releases use semver (`release/1.2.0`).

**Mandatory start**:

```bash
git checkout main && git pull origin main && git checkout -b {type}/{description}
```

**Task status**: move task to `## In Progress`, add `started:`, then `beads-sync-helper.sh push`.

**Lifecycle**: Create → Develop → Preflight → Push → PR → Review → Merge → Cleanup. Add Version/Release/Postflight only when shipping a release.

<!-- AI-CONTEXT-END -->

Read `workflows/git-workflow.md` before branch creation for issue URL handling, fork detection, and new repo setup.

**Names from planning files**: slugify the task description — lowercase, spaces→hyphens, special chars removed. See `git-workflow.md` for full rules.

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
| 11. Cleanup | Delete branch | `git branch -d {name}` / `git push origin --delete {name}` if needed | Yes |

On branch creation: move the task from `## Ready`/`## Backlog` to `## In Progress`, add `started:<ISO>`, then `beads-sync-helper.sh push`.

## Keeping Branch Updated

```bash
git checkout main && git pull origin main && git checkout your-branch && git merge main
# Resolve conflicts if needed — see tools/git/conflict-resolution.md
```

## Safety: Protecting Uncommitted Work

Before reset, clean, rebase, or checkout with local changes:

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

- `workflows/git-workflow.md` — issue URLs, fork detection, repo setup
- `workflows/pr.md` — PR creation and review
- `workflows/preflight.md` — quality checks before push
- `workflows/version-bump.md`, `workflows/changelog.md` — versioning
- `workflows/release.md`, `workflows/postflight.md` — release verification
- `workflows/code-audit-remote.md` — code review
