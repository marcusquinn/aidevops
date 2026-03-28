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

- **Purpose**: Ensure safe, traceable git workflow for all file changes
- **Trigger**: Read this when conversation indicates file creation/modification in a git repo
- **Principle**: Every change on a branch, never directly on main
- **CRITICAL**: With parallel sessions, ALWAYS verify branch state before ANY file operation

**Pre-Edit Gate** (MANDATORY before ANY file edit/write/create):

```bash
git branch --show-current  # If result is `main` → STOP
```

If on `main`: STOP. Present branch options before proceeding with any file changes.

**First Actions** (before any code changes):

```bash
git fetch origin                   # Parallel session safety
git status --short                 # Check for uncommitted work
git log --oneline HEAD..origin/$(git branch --show-current) 2>/dev/null
```

If remote has new commits: pull/rebase before continuing. If uncommitted local changes: stash or commit first.

**Git Worktrees for Parallel Work** (DEFAULT):

The main repo directory (`~/Git/{repo}/`) should ALWAYS stay on `main`. All feature work happens in worktree directories.

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/
```

If the main repo is left on a feature branch, the next session inherits that state, causing "local changes would be overwritten" errors. See `workflows/worktree.md` for full worktree workflow.

**Non-git artifacts do not transfer between worktrees.** Gitignored directories exist only where created.

| Artifact | Correct action |
|----------|----------------|
| `.venv/` (Python) | Create fresh venv inside worktree; never use canonical venv (broken `.pth` paths) |
| `node_modules/` | Run `npm install` / `pnpm install` inside worktree |
| `dist/`, `build/` | Run build command inside worktree |
| `.env` (gitignored) | Copy from canonical repo or recreate from `.env.example` |

See `tools/code-review/code-standards.md` "Python Projects" for Python packaging rules.

**Session-Branch Tracking**: After creating a branch, call `session-rename_sync_branch` to sync session name.

**Scope Monitoring**: When work evolves significantly from the branch name/purpose, offer to create a new branch, continue on current, or stash and switch.

**Decision Tree**:

| Situation | Action |
|-----------|--------|
| On `main` branch | Suggest branch creation (see below) |
| On feature/bugfix branch | Continue, follow `branch.md` lifecycle |
| Issue URL pasted | Parse and create appropriate branch |
| Non-owner repo | Fork workflow (see `pr.md`) |
| New empty repo | Initialize with `main`, suggest `release/0.1.0` |

<!-- AI-CONTEXT-END -->

## Time Tracking Integration

When creating branches, record the `started:` timestamp in TODO.md or PLANS.md. **Worker restriction**: Headless workers must NOT edit TODO.md — the supervisor handles all updates. See `workflows/plans.md`.

| Event | Field Updated |
|-------|---------------|
| Branch created | `started:` |
| Work session ends | `logged:` (cumulative) |
| PR merged | `completed:` |
| Release published | `actual:` |

## Branch Naming from TODO.md and PLANS.md

Check planning files before creating branches:

```bash
grep -i "{keyword}" TODO.md todo/PLANS.md
ls todo/tasks/*{keyword}* 2>/dev/null
```

| Source | Branch Name Pattern | Example |
|--------|---------------------|---------|
| TODO.md task | `{type}/{slugified-description}` | `feature/add-ahrefs-mcp-server` |
| PLANS.md entry | `{type}/{plan-slug}` | `feature/user-authentication-overhaul` |
| PRD file | `{type}/{prd-feature-name}` | `feature/export-csv` |

Slugification: lowercase, hyphens for spaces, remove special chars, truncate to ~50 chars.

## Branch-First Development

Every code change should happen on a branch, enabling safe parallel work, full traceability, easy rollback, code review, and blame history.

## Destructive Command Safety Hooks

Claude Code PreToolUse hooks block destructive git and filesystem commands before they execute.

**Blocked commands:**

| Command | Risk |
|---------|------|
| `git checkout -- <files>` | Discards uncommitted changes permanently |
| `git restore <files>` | Same effect (newer syntax) |
| `git reset --hard` | Destroys all uncommitted work |
| `git clean -f` | Deletes untracked files permanently |
| `git push --force` / `-f` | Overwrites remote history |
| `git branch -D` | Force-deletes without merge check |
| `rm -rf` (non-temp paths) | Recursive deletion |
| `git stash drop/clear` | Permanently deletes stashes |

**Safe patterns (allowlisted):** `git checkout -b`, `git restore --staged`, `git clean -n`/`--dry-run`, `rm -rf /tmp/...`, `git push --force-with-lease`.

```bash
install-hooks-helper.sh status    # Check status
install-hooks-helper.sh install   # Reinstall
install-hooks-helper.sh test      # Run self-test (20 test cases)
install-hooks-helper.sh uninstall # Remove
```

Files: `~/.aidevops/hooks/git_safety_guard.py` (guard), `~/.claude/settings.json` (config). Installed automatically by `setup.sh`. Requires Python 3 and a Claude Code restart.

**Limitations**: Regex-based; obfuscated commands may bypass it. Safety net for honest mistakes, not a security boundary. OpenCode does not currently support hooks (instruction-based only).

## Conversation Start: Git Context Check

```bash
git rev-parse --is-inside-work-tree 2>/dev/null || echo "NOT_GIT_REPO"
git branch --show-current
git branch -a | grep -E "(feature|bugfix|hotfix|refactor|chore|experiment|release)/"
git status --short
grep -A 20 "## In Progress" TODO.md | grep "^\- \[ \]"
```

If on `main`, auto-select best match from planning files and confirm with user. Always use worktrees, not `git checkout -b`. If existing branch matches, auto-select it.

## Issue URL Handling

Parse issue URLs to extract platform, owner, repo, and issue number, then create a worktree:

```bash
# Clone if not local: gh repo clone {owner}/{repo} ~/Git/{repo}
git checkout main && git pull origin main
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add {type}/{issue_number}-{slug-from-title}
```

Supported: `github.com/{owner}/{repo}/issues/{num}`, `gitlab.com/{owner}/{repo}/-/issues/{num}`, `{domain}/{owner}/{repo}/issues/{num}` (Gitea).

**Repository ownership**: If `git remote get-url origin` owner differs from `gh api user --jq '.login'`, use fork workflow — see `workflows/pr.md`.

## New Repository Initialization

```bash
git init && git checkout -b main
echo "# Project Name" > README.md
git add README.md && git commit -m "chore: initial commit"
```

Suggest `release/0.1.0` for new projects, `release/1.0.0` for MVP, or `release/X.Y.Z` (current + patch) for existing projects adopting aidevops.

## Branch Type Selection

| If user mentions... | Branch Type | Example |
|---------------------|-------------|---------|
| "add", "new", "feature", "implement" | `feature/` | `feature/user-auth` |
| "fix", "bug", "broken", "error" | `bugfix/` | `bugfix/login-timeout` |
| "urgent", "critical", "production down" | `hotfix/` | `hotfix/security-patch` |
| "refactor", "cleanup", "restructure" | `refactor/` | `refactor/api-cleanup` |
| "docs", "readme", "documentation" | `chore/` | `chore/update-docs` |
| "update deps", "config", "maintenance" | `chore/` | `chore/update-deps` |
| "try", "experiment", "POC", "spike" | `experiment/` | `experiment/new-ui` |
| "release", "version" | `release/` | `release/1.2.0` |

See `workflows/branch.md` for naming conventions.

## Workflow Lifecycle

```text
1. CONVERSATION START → detect git context, check branch, suggest/create branch
   └── See: workflows/branch.md
2. DEVELOPMENT → work on branch, conventional commits, keep updated with main
   └── See: workflows/branch.md
3. PREFLIGHT → linters-local.sh, code quality, secret check
   └── See: workflows/preflight.md
4. PUSH & PR → push branch, create PR/MR, run code-audit-remote
   └── See: workflows/pr.md
5. REVIEW & MERGE → address feedback, squash merge, delete feature branch
   └── See: workflows/pr.md
6. RELEASE PREPARATION → release/X.Y.Z branch, version files, changelog
   └── See: workflows/version-bump.md
7. RELEASE → merge to main, tag, GitHub release, delete release branch
   └── See: workflows/release.md
8. POSTFLIGHT → verify CI/CD, quality gates, cleanup offer
   └── See: workflows/postflight.md
9. CLEANUP → delete merged branches, prune stale refs, update local main
```

## Post-Change Workflow

After completing file changes, run preflight automatically. If preflight passes, auto-commit with suggested message (confirm or override). If preflight fails, show issues and offer fixes. After successful commit, auto-push and offer: create PR, continue working, or done.

**PR Title (MANDATORY)**: `{task-id}: {description}` (e.g., `t318: Update PR workflow documentation`). For unplanned work: create TODO entry first. Every code change must be traceable to a task — even 1-line fixes.

**If changes include `.agents/` files**: Offer to run `./setup.sh` to deploy to `~/.aidevops/agents/`.

## Branch Cleanup

```bash
git checkout main && git pull origin main
git branch --merged main | grep -vE "^\*|main|develop"
git branch -d {branch-name}            # Local
git push origin --delete {branch-name} # Remote
git remote prune origin
```

Delete merged branches after postflight passes. Keep unmerged branches unless stale (>30 days) — ask user about status.

## Override Handling

When user wants to work directly on main, acknowledge and proceed — never block the user. Note the trade-offs (harder rollback, no PR review, harder to collaborate) and continue.

## Database Schema Changes

When changes include schema modifications, look for: `schemas/`, `migrations/`, SQL files, ORM schema files (Drizzle `.ts`, Prisma `.prisma`).

**Declarative Schema Workflow** (when `schemas/` exists):

1. Edit schema files in `schemas/`
2. Generate migration: `supabase db diff -f desc` / `npx drizzle-kit generate` / `npx prisma migrate dev --name desc`
3. Review generated migration in `migrations/`
4. Apply locally, then commit schema + migration together

**Critical rules**:
- NEVER modify migrations that have been pushed/deployed — create a new migration to fix issues
- ALWAYS commit schema and migration files together
- ALWAYS review generated migrations before committing

Branch naming: `feature/add-{table}-table`, `bugfix/fix-{description}`, `chore/backfill-{description}`.

See `workflows/sql-migrations.md` for full migration workflow.

## Related Workflows

| Workflow | When to Read |
|----------|--------------|
| `branch.md` | Branch naming, creation, lifecycle |
| `pr.md` | PR creation, review, merge, fork workflow |
| `preflight.md` | Quality checks before push |
| `postflight.md` | Verification after release |
| `version-bump.md` | Version management, release branches |
| `release.md` | Full release process |
| `sql-migrations.md` | Database schema version control |
| `tools/git/lumen.md` | AI-powered diffs, commit messages |
| `tools/security/opsec.md` | CI/CD AI agent security |

## Platform CLI Reference

| Platform | CLI | PR | Release |
|----------|-----|----|---------|
| GitHub | `gh` | `gh pr create` | `gh release create` |
| GitLab | `glab` | `glab mr create` | `glab release create` |
| Gitea | `tea` | `tea pulls create` | `tea releases create` |

See `tools/git.md` for detailed CLI usage.
