---
description: Master git workflow orchestrator - read when coding work begins
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

# Git Workflow Orchestrator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Principle**: Every change on a branch, never directly on main
- **CRITICAL**: With parallel sessions, ALWAYS verify branch state before ANY file operation

**Pre-Edit Gate** (MANDATORY before ANY file edit/write/create):

```bash
git branch --show-current  # If `main` → STOP, present branch options
```

**First Actions** (before code changes): `git fetch origin && git status --short`. Remote ahead → pull/rebase. Uncommitted changes → stash or commit.

**Worktrees** (DEFAULT for all feature work):

Main repo (`~/Git/{repo}/`) stays on `main`. All work in worktree directories.

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/
```

Non-git artifacts (`.venv/`, `node_modules/`, `dist/`, `.env`) don't transfer — recreate per worktree. See `workflows/worktree.md`, `tools/code-review/code-standards.md`.

**Session-Branch Tracking**: After creating a branch, call `session-rename_sync_branch`.

**Scope Monitoring**: When work diverges from branch purpose, offer: new branch, continue, or stash and switch.

<!-- AI-CONTEXT-END -->

## Decision Tree

| Situation | Action |
|-----------|--------|
| On `main` | Create worktree — see `branch.md` for type selection |
| On feature/bugfix branch | Continue, follow `branch.md` lifecycle |
| Issue URL pasted | Parse and create branch (see Issue URL Handling) |
| Non-owner repo | Fork workflow — see `pr.md` |
| New empty repo | `git init && git checkout -b main`; suggest `release/0.1.0` (new), `release/1.0.0` (MVP), or `release/X.Y.Z` (existing) |

## Time Tracking

Record in TODO.md or PLANS.md. **Workers must NOT edit TODO.md** — supervisor handles. See `workflows/plans.md`.

| Event | Field | Event | Field |
|-------|-------|-------|-------|
| Branch created | `started:` | PR merged | `completed:` |
| Session ends | `logged:` (cumulative) | Release published | `actual:` |

## Branch Naming from Planning Files

Lookup: `grep -i "{keyword}" TODO.md todo/PLANS.md 2>/dev/null` and `ls todo/tasks/*{keyword}* 2>/dev/null`.

| Source | Pattern | Example |
|--------|---------|---------|
| TODO.md task | `{type}/{slugified-description}` | `feature/add-ahrefs-mcp-server` |
| PLANS.md / PRD | `{type}/{plan-or-feature-slug}` | `feature/user-authentication-overhaul` |

Slugify: lowercase, hyphens, no special chars, ~50 char max. Type selection: see `branch.md`.

## Issue URL Handling

Parse issue URLs → extract platform, owner, repo, number → create worktree:

```bash
# Clone if not local: gh repo clone {owner}/{repo} ~/Git/{repo}
git checkout main && git pull origin main
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add {type}/{issue_number}-{slug-from-title}
```

Supported: `github.com`, `gitlab.com` (`/-/issues/`), Gitea (`{domain}/{owner}/{repo}/issues/{num}`).

**Ownership check**: If `git remote get-url origin` owner differs from `gh api user --jq '.login'`, use fork workflow — see `workflows/pr.md`.

## Destructive Command Safety Hooks

PreToolUse hooks block destructive git/filesystem commands before execution.

**Blocked**: `git checkout -- <files>`, `git restore <files>`, `git reset --hard`, `git clean -f`, `git push --force`/`-f`, `git branch -D`, `rm -rf` (non-temp), `git stash drop/clear`.

**Safe**: `git checkout -b`, `git restore --staged`, `git clean -n`/`--dry-run`, `rm -rf /tmp/...`, `git push --force-with-lease`.

Manage: `install-hooks-helper.sh [status|install|test|uninstall]`. Installed by `setup.sh`. Regex-based — safety net, not security boundary.

## Post-Change Workflow

After changes: run preflight. Pass → auto-commit (confirm/override message). Fail → show issues, offer fixes. After commit → auto-push, offer: create PR, continue, or done.

**PR Title**: See AGENTS.md "Git Workflow" — `{task-id}: {description}` format is mandatory.

**If changes include `.agents/` files**: Offer to run `./setup.sh` to deploy.

## Branch Cleanup

After postflight, delete merged branches. Keep unmerged unless stale (>30 days) — ask user.

```bash
git checkout main && git pull origin main
git branch --merged main | grep -vE '^\*|^(main|develop)$' | xargs -r git branch -d
git push origin --delete {branch-name}  # Remote
git remote prune origin
```

## Override Handling

When user wants to work directly on main, acknowledge and proceed — never block. Note trade-offs (harder rollback, no PR review, harder collaboration) and continue.

## Database Schema Changes

See `workflows/sql-migrations.md`. Critical: never modify pushed migrations — create new ones. Commit schema + migration together. Review generated migrations before committing.

## Related Workflows

| Workflow | When to Read |
|----------|--------------|
| `branch.md` | Branch naming, type selection, lifecycle |
| `worktree.md` | Worktree creation, management, cleanup |
| `pr.md` | PR creation, review, merge, fork workflow |
| `preflight.md` | Quality checks before push |
| `postflight.md` | Verification after release |
| `version-bump.md` | Version management, release branches |
| `release.md` | Full release process |
| `sql-migrations.md` | Database schema version control |
| `tools/git/lumen.md` | AI-powered diffs, commit messages |
| `tools/security/opsec.md` | CI/CD AI agent security |

**Platform CLIs**: GitHub (`gh`), GitLab (`glab`), Gitea (`tea`). See `tools/git.md`.
