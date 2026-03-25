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
git branch --show-current          # PRE-EDIT GATE — if main → STOP
git remote -v | head -1            # Check repo ownership
git status --short                 # Check for uncommitted work
git fetch origin                   # Parallel session safety
git log --oneline HEAD..origin/$(git branch --show-current) 2>/dev/null
```

**Parallel Session Safety**:

| Situation | Action |
|-----------|--------|
| Remote has new commits | Pull/rebase before continuing |
| Uncommitted local changes | Stash or commit before switching |
| Different session on same branch | Coordinate or use separate branches |
| Starting new work | Always create a new branch first |
| **Multiple parallel sessions** | **Use git worktrees** (see below) |

**Git Worktrees for Parallel Work** (DEFAULT):

The main repo directory (`~/Git/{repo}/`) should ALWAYS stay on `main`. All feature work happens in worktree directories.

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/

${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh list
```

If the main repo is left on a feature branch, the next session inherits that state, causing "local changes would be overwritten" errors and breaking parallel workflows. See `workflows/worktree.md` for full worktree workflow.

**Session-Branch Tracking**:

| Tool/Command | Purpose |
|--------------|---------|
| `session-rename_sync_branch` | AI tool: auto-sync session name with current git branch |
| `session-rename` | AI tool: set custom session title |
| `/sync-branch` | Slash command: rename session to match current git branch |

Best practice: after creating a branch, call `session-rename_sync_branch` to sync session name.

**Scope Monitoring** (during session):

When work evolves significantly from the branch name/purpose, proactively offer:

> This work (`{description}`) seems outside the scope of `{current-branch}`.
>
> 1. Create new branch `{suggested-type}/{suggested-name}` (recommended)
> 2. Continue on current branch (if intentionally expanding scope)
> 3. Stash changes and switch to existing branch

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

When creating branches, record the `started:` timestamp in TODO.md or PLANS.md.

**Worker restriction**: Headless dispatch workers must NOT edit TODO.md directly. The supervisor handles all TODO.md updates. See `workflows/plans.md` "Worker TODO.md Restriction".

| Event | Action | Field Updated |
|-------|--------|---------------|
| Branch created | Record start time | `started:` |
| Work session ends | Log time spent | `logged:` (cumulative) |
| PR merged | Record completion | `completed:` |
| Release published | Calculate actual | `actual:` |

See `workflows/plans.md` for full time tracking format.

## Branch Naming from TODO.md and PLANS.md

Check planning files before creating branches:

```bash
grep -i "{keyword}" TODO.md
grep -i "{keyword}" todo/PLANS.md
ls todo/tasks/*{keyword}* 2>/dev/null
```

| Source | Branch Name Pattern | Example |
|--------|---------------------|---------|
| TODO.md task | `{type}/{slugified-description}` | `feature/add-ahrefs-mcp-server` |
| PLANS.md entry | `{type}/{plan-slug}` | `feature/user-authentication-overhaul` |
| PRD file | `{type}/{prd-feature-name}` | `feature/export-csv` |

Slugification: lowercase, hyphens for spaces, remove special chars, truncate to ~50 chars.

## Core Principle: Branch-First Development

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
# Step 1: Detect git context
git rev-parse --is-inside-work-tree 2>/dev/null || echo "NOT_GIT_REPO"
git branch --show-current
git rev-parse --show-toplevel

# Step 2: Check for existing branches
git branch -a | grep -E "(feature|bugfix|hotfix|refactor|chore|experiment|release)/"
git status --short

# Step 3: Check planning files
grep -A 20 "## In Progress" TODO.md | grep "^\- \[ \]"
grep -i "{user_request_keywords}" TODO.md
grep -A 5 "^### \[" todo/PLANS.md | grep -i "{user_request_keywords}"
```

**Step 4: Auto-Select with Override Options**

If on `main`, auto-select best match:

> On `main`. Creating worktree for `feature/{best-match-name}` (from {source}).
>
> [Enter] to confirm, or: 1. Use different name  2. Continue on `main` (docs-only, not recommended for code)

Always use worktrees, not `git checkout -b`. The main repo directory must stay on `main`.

If existing branch matches, auto-select it. If already on a work branch, just continue.

## Issue URL Handling

| Platform | Pattern |
|----------|---------|
| GitHub | `github.com/{owner}/{repo}/issues/{num}` |
| GitLab | `gitlab.com/{owner}/{repo}/-/issues/{num}` |
| Gitea | `{domain}/{owner}/{repo}/issues/{num}` |

```bash
# 1. Parse URL → platform, owner, repo, issue_number
# 2. Clone if not local: gh repo clone {owner}/{repo} ~/Git/{repo}
# 3. Create worktree for the issue
git checkout main && git pull origin main
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add {type}/{issue_number}-{slug-from-title}
# Creates: ~/Git/{repo}-{type}-{issue_number}-{slug}/
```

## Repository Ownership Check

```bash
REMOTE_URL=$(git remote get-url origin)
REPO_OWNER=$(echo "$REMOTE_URL" | sed -E 's/.*[:/]([^/]+)\/[^/]+\.git$/\1/')
CURRENT_USER=$(gh api user --jq '.login')
if [[ "$REPO_OWNER" != "$CURRENT_USER" ]]; then
    echo "NON_OWNER: Fork workflow required"
fi
```

If non-owner: see `workflows/pr.md` for fork workflow.

## New Repository Initialization

```bash
git init && git checkout -b main
echo "# Project Name" > README.md
git add README.md && git commit -m "chore: initial commit"
```

| Project State | Suggested Version | Branch |
|---------------|-------------------|--------|
| New project, no features | 0.1.0 | `release/0.1.0` |
| MVP ready | 1.0.0 | `release/1.0.0` |
| Existing project, first aidevops use | Current + patch | `release/X.Y.Z` |

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

After completing file changes, run preflight automatically.

**If preflight passes**, auto-commit with suggested message:

> Preflight passed. Committing: "{suggested message}"
>
> [Enter] to confirm, or: 1. Use different message  2. Make more changes first

**If preflight fails**, show issues and offer fixes.

**After successful commit**, auto-push if on a branch:

> Committed and pushed to `{branch}`.
>
> 1. Create PR  2. Continue working  3. Done for now

### PR Title Requirements

**MANDATORY**: All PR titles MUST include the task ID from TODO.md.

**Format**: `{task-id}: {description}` (e.g., `t318: Update PR workflow documentation`)

**For unplanned work**: Create TODO entry first (`- [ ] t999 Fix typo ~15m #hotfix`), then create PR with that task ID. Every code change must be traceable to a task — even 1-line fixes.

**If changes include `.agents/` files**: Offer to run `./setup.sh` to deploy to `~/.aidevops/agents/`.

## Branch Cleanup

```bash
git checkout main && git pull origin main
git branch --merged main | grep -vE "^\*|main|develop"
git branch -d {branch-name}            # Local
git push origin --delete {branch-name} # Remote
git remote prune origin
```

| Branch State | Action |
|--------------|--------|
| Merged + postflight passed | Safe to delete |
| Merged + postflight failed | Keep, may need hotfix |
| Unmerged + stale (>30 days) | Ask user about status |
| Unmerged + active | Keep |

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

| Change Type | Branch |
|-------------|--------|
| New table | `feature/add-{table}-table` |
| Schema fix | `bugfix/fix-{description}` |
| Data backfill | `chore/backfill-{description}` |

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
