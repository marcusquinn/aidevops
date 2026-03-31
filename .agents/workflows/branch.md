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

- **Resume first**: `git worktree list` or `wt list`
- **Preferred start**: `wt switch -c {type}/{name}` from the canonical repo on `main`
- **Fallback**: `worktree-helper.sh add {type}/{name}`
- **Canonical repo rule**: keep `~/Git/{repo}/` on `main`; do branch work in the linked worktree path

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

**Start**: `wt switch -c {type}/{description}`. Fallback: `worktree-helper.sh add {type}/{description}`.

**Task status**: move the task to `## In Progress`, add `started:<ISO>`, then `beads-sync-helper.sh push`.

**Lifecycle**: Create → Develop → Preflight → Push → PR → Review → Merge → Cleanup. Add Version → Release → Postflight only for releases.

<!-- AI-CONTEXT-END -->

Read `workflows/git-workflow.md` before branch creation for issue URL handling, fork detection, commit/PR rules, and repo setup. Read `workflows/worktree.md` for worktree creation and cleanup. Names from planning files: slugify the task description — lowercase, spaces→hyphens, special chars removed.

## Branch Lifecycle

| Stage | Action | Command / Agent | Required |
|-------|--------|-----------------|----------|
| 1. Create | Create linked worktree from `main` | `wt switch -c {type}/{desc}` or `worktree-helper.sh add {type}/{desc}` | Yes |
| 2. Develop | Conventional commits | `branch/{type}.md`, domain agents | Yes |
| 3. Preflight | Local quality checks | `.agents/scripts/linters-local.sh --fast` → `workflows/preflight.md` | Yes |
| 4. Version | Bump for releases | `.agents/scripts/version-manager.sh bump [major\|minor\|patch]` → `workflows/version-bump.md` | Releases only |
| 5. Push | Remote backup | `git push -u origin HEAD` | Yes |
| 6. PR | Create PR/MR | `gh pr create --fill` / `glab mr create --fill` → `workflows/pr.md` | Yes |
| 7. Review | Address feedback | `git add . && git commit -m "fix: ..." && git push` → `workflows/code-audit-remote.md` | Yes |
| 8. Merge | Squash merge | `gh pr merge --squash` | Yes |
| 9. Release | Tag and publish | `.agents/scripts/version-manager.sh release [major\|minor\|patch]` → `workflows/release.md` | Releases only |
| 10. Postflight | Verify CI/CD | `gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status` → `workflows/postflight.md` | Releases only |
| 11. Cleanup | Remove merged worktree and delete branch if needed | `worktree-helper.sh remove {type}/{desc}` / `git push origin --delete {name}` | Yes |

## Worktree Rules

- Prefer worktrees over `git checkout -b` in the canonical repo; the next session must inherit `main`, not a task branch.
- Talk about the worktree path (`~/Git/{repo}-{type}-{slug}/`), not "switching the main repo to a branch".
- After switching to a worktree, re-read files at the worktree path before editing.
- Never remove a worktree you did not create unless the user explicitly asked.

## Keeping Branch Updated

```bash
git fetch origin main
git merge origin/main
# Or rebase if the repo workflow requires it; resolve conflicts with tools/git/conflict-resolution.md
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

Use conventional commits: `feat:` `fix:` `refactor:` `docs:` `chore:` `test:`. Include issue references when the repo workflow requires them.

## Related Workflows

- `workflows/git-workflow.md` — issue URLs, commit/PR rules, repo setup
- `workflows/worktree.md` — worktree creation, ownership, cleanup
- `workflows/pr.md` — PR creation and review
- `workflows/preflight.md` — quality checks before push
- `workflows/version-bump.md`, `workflows/changelog.md` — versioning
- `workflows/release.md`, `workflows/postflight.md` — release verification
- `workflows/code-audit-remote.md` — code review
