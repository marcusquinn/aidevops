---
description: Git branch creation and management workflow
mode: subagent
tools:
  read: true
  bash: true
  glob: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worktree Ref Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- Resume existing work first: `git worktree list` or `wt list`
- Start from canonical repo on `main`: `wt switch -c {type}/{name}`
- Fallback: `${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add {type}/{name}`, then `cd` into the printed linked worktree path
- Keep `~/Git/{repo}/` or grouped `~/Git/{ecosystem}/{repo}/` on `main`; do task work in the linked worktree path under `${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}`

| Task Type | Branch Prefix | Subagent |
|-----------|---------------|----------|
| New functionality | `feature/` | `branch/feature.md` |
| Bug fix | `bugfix/` | `branch/bugfix.md` |
| Urgent production fix | `hotfix/` | `branch/hotfix.md` |
| Code restructure | `refactor/` | this file, "Chore, Refactor, Release, Experiment" |
| Docs, deps, config | `chore/` | this file, "Chore, Refactor, Release, Experiment" |
| Spike, POC | `experiment/` | this file, "Chore, Refactor, Release, Experiment" |
| Version release | `release/` | this file, "Chore, Refactor, Release, Experiment" |

- Worktree refs: `{type}/{short-description}` — lowercase, hyphenated, ~50 chars max. Examples: `feature/user-dashboard`, `bugfix/123-login-timeout`; releases use semver (`release/1.2.0`).
- Planning tasks: move to `## In Progress` and add `started:<ISO>`.

<!-- AI-CONTEXT-END -->

Before creating a safe linked worktree, read `workflows/git-workflow.md` (issue URLs, fork detection, commit/PR rules) and `workflows/worktree.md` (creation, cleanup). Pre-slugify worktree refs: lowercase, spaces→hyphens, special chars removed. Worktree paths auto-slugified by `generate_worktree_path()` (`/` → `-`, lowercased).

## Branch Lifecycle

Commits: conventional (`feat:` `fix:` `refactor:` `docs:` `chore:` `test:`). Include issue refs when the repo workflow requires them.

| Stage | Command / Agent | Notes |
|-------|-----------------|-------|
| Create | `wt switch -c {type}/{desc}` or `${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add {type}/{desc}` then `cd` into the printed path | Safe linked worktree from `main` |
| Develop | `branch/{type}.md`, domain agents | Use conventional commits |
| Preflight | `.agents/scripts/linters-local.sh --fast` → `workflows/preflight.md` | Required before push |
| Version | `.agents/scripts/version-manager.sh bump [major\|minor\|patch]` → `workflows/version-bump.md` | Releases only |
| Push | `git push -u origin HEAD` | Remote backup |
| PR | `gh pr create --fill` / `glab mr create --fill` → `workflows/pr.md` | Required |
| Review | `git add . && git commit -m "fix: ..." && git push` → `workflows/code-audit-remote.md` | Address feedback |
| Merge | `full-loop-helper.sh merge NUMBER OWNER/REPO --squash` | Required lifecycle gate |
| Release | `.agents/scripts/version-manager.sh release [major\|minor\|patch]` → `workflows/release.md` | Releases only |
| Postflight | `gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status` → `workflows/postflight.md` | Releases only |
| Cleanup | `worktree-helper.sh remove {type}/{desc}` / `git push origin --delete {name}` | Remove merged worktree; delete branch if needed |

## Chore, Refactor, Release, Experiment

| Type | Prefix | Commit | Version | Notes |
|------|--------|--------|---------|-------|
| Chore | `chore/` | `chore:`, `docs:`, `ci:`, `build:` | None | Dependency, CI/CD, docs, build, tooling maintenance, formatting/linting fixes, license/`.gitignore` updates. Not for behavior changes — use `feature/`, `bugfix/`, or `refactor/`. |
| Refactor | `refactor/` | `refactor: description` | Usually none | Code restructuring without behavior change: extracting reusable components, reducing technical debt, same-behavior performance improvements. **Golden rule: same inputs → same outputs**; if behavior changes, split into `bugfix/`/`feature/` or document the intentional change. Exercise the unchanged production path and run applicable checks before and after; reviewers verify no behavior change and no regression. |
| Release | `release/{MAJOR}.{MINOR}.{PATCH}` | `chore(release): v{version}` | Bump per scope (patch/minor/major); urgent fixes use `hotfix/` instead | Bump version and update `CHANGELOG.md` (`version-manager.sh bump {patch\|minor\|major}`); reuse terminal CI/lint evidence for the exact release SHA, running `linters-local.sh --full` only when SHA-matched evidence is unavailable; after implementation PRs merge, release from a fresh detached worktree (`git worktree add --detach ... origin/main`, never switch canonical HEAD); tag and push (`git tag -a v{VERSION} -m "Release v{VERSION}"`, `git push origin v{VERSION}`, `gh release create v{VERSION} --generate-notes`); run postflight. See `workflows/version-bump.md`, `workflows/release.md`, `workflows/changelog.md`, `workflows/postflight.md`. |
| Experiment | `experiment/` | `experiment:` or `spike:` | None — experiments don't get released | POC, technical spikes, exploring new approaches, testing third-party integrations, performance experiments, architecture exploration. **May never merge — that's a valid outcome.** Record the hypothesis and expected outcome in the first commit; document results (proceeding/not proceeding, learnings) in the PR regardless of outcome. If it succeeds, don't merge the experiment directly — create a new `feature/` worktree from `main` and reimplement cleanly, referencing the experiment branch for context. |

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add {chore|refactor|release|experiment}/{description}
# Then cd into the linked worktree path printed by the helper before editing.
```

## Worktree Rules

- Create a safe linked worktree for every development task; the next session must inherit `main`, not a task ref.
- Reference the linked worktree path (`~/Git/_worktrees/{repo}-{type}-{slug}/` by default), not "switching the main repo to a branch".
- After switching to a worktree, re-read files at the worktree path before editing.
- Never remove a worktree you did not create unless the user explicitly asked.

## Keeping Branch Updated

```bash
git fetch origin main && git merge origin/main
# Rebase if required; conflicts → tools/git/conflict-resolution.md
```

## Safety: Protecting Uncommitted Work

Before reset, clean, rebase, or checkout with local changes:

```bash
git stash --include-untracked -m "safety: before [operation]"
# ... perform operation ...
git stash pop   # or: git stash show -p to review on conflict
```

`git restore` only recovers tracked files — untracked files are permanently lost without stash.

## Related Workflows

| Workflow | Purpose |
|----------|---------|
| `workflows/git-workflow.md` | Issue URLs, commit/PR rules, repo setup |
| `workflows/worktree.md` | Worktree creation, ownership, cleanup |
| `workflows/pr.md` | PR creation and review |
| `workflows/preflight.md` | Quality checks before push |
| `workflows/version-bump.md`, `workflows/changelog.md` | Versioning |
| `workflows/release.md`, `workflows/postflight.md` | Release verification |
| `workflows/code-audit-remote.md` | Code review |
