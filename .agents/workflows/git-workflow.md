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
# 1. Check current branch (PRE-EDIT GATE)
git branch --show-current
# If on main → STOP and create branch first

# 2. Check repo ownership
git remote -v | head -1

# 3. Check for uncommitted work
git status --short

# 4. Check for remote updates (parallel session safety)
git fetch origin
git log --oneline HEAD..origin/$(git branch --show-current) 2>/dev/null
```

**Parallel Session Safety**:

When running multiple OpenCode sessions on the same repo:

| Situation | Action |
|-----------|--------|
| Remote has new commits | Pull/rebase before continuing |
| Uncommitted local changes | Stash or commit before switching |
| Different session on same branch | Coordinate or use separate branches |
| Starting new work | Always create a new branch first |
| **Multiple parallel sessions** | **Use git worktrees** (see below) |

**Git Worktrees for Parallel Work** (DEFAULT):

**Core principle**: The main repo directory (`~/Git/{repo}/`) should ALWAYS stay on `main`. All feature work happens in worktree directories.

```bash
# Create separate working directory for a branch
~/.aidevops/agents/scripts/worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/

# List all worktrees
~/.aidevops/agents/scripts/worktree-helper.sh list

# Each terminal/session works in its own directory
# No branch switching affects other sessions
```

**Why this matters**: If the main repo is left on a feature branch, the next session inherits that state. This causes "local changes would be overwritten" errors and breaks parallel workflows.

See `workflows/worktree.md` for full worktree workflow.

**Session-Branch Tracking**:

OpenCode auto-generates session titles from the first prompt. To sync session names with branches:

| Tool/Command | Purpose |
|--------------|---------|
| `session-rename_sync_branch` | **AI tool**: Auto-sync session name with current git branch |
| `session-rename` | **AI tool**: Set custom session title |
| `/sync-branch` | **Slash command**: Rename session to match current git branch |
| `/rename feature/xyz` | **Slash command**: Rename session to any title |
| `/sessions` (Ctrl+x l) | List all sessions by name |

| Workflow | How to Track |
|----------|--------------|
| **New session, known work** | Start with: `opencode --title "feature/my-feature"` |
| **Existing session, new branch** | Call `session-rename_sync_branch` tool after creating branch |
| **Multiple sessions** | Each session named after its branch |
| **Resume work** | `opencode -c` continues last session, or `-s <id>` for specific |

**Best Practice**: After creating a branch, call `session-rename_sync_branch` tool to sync session name.

**Scope Monitoring** (during session):

When work evolves significantly from the branch name/purpose:

| Signal | Example | Action |
|--------|---------|--------|
| Different feature area | Branch is `chore/update-deps`, now adding new API endpoint | Suggest new branch |
| Unrelated bug fix | Branch is `feature/user-auth`, found unrelated CSS bug | Suggest separate branch |
| Scope expansion | Branch is `bugfix/login-timeout`, now refactoring entire auth system | Suggest `refactor/` branch |
| Command/API rename | Branch is `chore/optimize-X`, now renaming unrelated commands | Suggest new branch |

**When detected**, proactively offer:

> This work (`{description}`) seems outside the scope of `{current-branch}` ({original-purpose}).
>
> 1. Create new branch `{suggested-type}/{suggested-name}` (recommended)
> 2. Continue on current branch (if intentionally expanding scope)
> 3. Stash changes and switch to existing branch

**Stash workflow** (if user chooses option 1 or 3):

```bash
git stash --include-untracked -m "WIP: {description}"
git checkout main && git pull origin main
git checkout -b {type}/{description}
git stash pop
```

**Self-check trigger**: Before each file edit, briefly consider: "Does this change align with `{branch-name}`?"

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

### Recording Start Time

After creating a branch (interactive sessions only), update the corresponding task in TODO.md:

```bash
# Find the task and add started: timestamp
# Before: - [ ] Add Ahrefs MCP server #seo ~4h
# After:  - [ ] Add Ahrefs MCP server #seo ~4h started:2025-01-15T10:30Z
```

For PLANS.md entries, update the plan's status section:

```markdown
### [2025-01-15] User Authentication Overhaul
**Status:** In Progress
**Started:** 2025-01-15T10:30Z
**Branch:** feature/user-auth-overhaul
```

### Time Tracking Workflow

| Event | Action | Field Updated |
|-------|--------|---------------|
| Branch created | Record start time | `started:` |
| Work session ends | Log time spent | `logged:` (cumulative) |
| PR merged | Record completion | `completed:` |
| Release published | Calculate actual | `actual:` |

See `workflows/plans.md` for full time tracking format.

## Branch Naming from TODO.md and PLANS.md

When creating branches, derive names from planning files when available:

### Check Planning Files First

```bash
# Check TODO.md for matching task
grep -i "{keyword}" TODO.md

# Check PLANS.md for matching plan
grep -i "{keyword}" todo/PLANS.md

# Check for PRD/tasks files
ls todo/tasks/*{keyword}* 2>/dev/null
```

### Branch Name Derivation

| Source | Branch Name Pattern | Example |
|--------|---------------------|---------|
| TODO.md task | `{type}/{slugified-description}` | `feature/add-ahrefs-mcp-server` |
| PLANS.md entry | `{type}/{plan-slug}` | `feature/user-authentication-overhaul` |
| PRD file | `{type}/{prd-feature-name}` | `feature/export-csv` |
| Multiple tasks | `{type}/{summary-slug}` | `feature/seo-improvements` |

### Slugification Rules

- Lowercase all text
- Replace spaces with hyphens
- Remove special characters except hyphens
- Truncate to ~50 chars if needed
- Remove common words (the, a, an) if too long

**Examples:**

| Task/Plan | Generated Branch |
|-----------|------------------|
| `- [ ] Add Ahrefs MCP server integration #seo` | `feature/add-ahrefs-mcp-server` |
| `- [ ] Fix login timeout bug #auth` | `bugfix/fix-login-timeout` |
| `### [2025-01-15] User Authentication Overhaul` | `feature/user-authentication-overhaul` |
| `prd-export-csv.md` | `feature/export-csv` |

## Core Principle: Branch-First Development

Every code change should happen on a branch, enabling:

- **Safe parallel work** - Multiple developers without conflicts
- **Full traceability** - Every change linked to branch → PR → merge
- **Easy rollback** - Revert branches without affecting main
- **Code review** - PRs enable review before merge
- **Blame history** - Track who did what, when, and why

## Destructive Command Protection

Claude Code PreToolUse hooks mechanically block destructive git and filesystem commands before they execute. AGENTS.md instructions alone cannot prevent accidents - this provides enforcement at the tool level.

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

**Management:**

```bash
# Check status
install-hooks-helper.sh status

# Reinstall
install-hooks-helper.sh install

# Run self-test (20 test cases)
install-hooks-helper.sh test

# Remove if needed
install-hooks-helper.sh uninstall
```

**Files:**

- Hook script: `~/.aidevops/hooks/git_safety_guard.py`
- Configuration: `~/.claude/settings.json` (hooks.PreToolUse)
- Source: `.agents/hooks/git_safety_guard.py`
- Installer: `.agents/scripts/install-hooks-helper.sh`

**Installed automatically** by `setup.sh`. Requires Python 3 and a Claude Code restart after installation.

## Conversation Start: Git Context Check

When a conversation indicates file work will happen (code, docs, config, assets, etc.):

### Step 1: Detect Git Context

```bash
# Check if in a git repo
git rev-parse --is-inside-work-tree 2>/dev/null || echo "NOT_GIT_REPO"

# Get current branch
git branch --show-current

# Get repo root
git rev-parse --show-toplevel
```

### Step 2: Check for Existing Branches

Before suggesting a new branch, check for existing work that might match:

```bash
# List work-in-progress branches
git branch -a | grep -E "(feature|bugfix|hotfix|refactor|chore|experiment|release)/"

# Check for uncommitted changes
git status --short
```

### Step 3: Check Planning Files

Before suggesting branch names, check for matching tasks/plans:

```bash
# Check TODO.md In Progress section
grep -A 20 "## In Progress" TODO.md | grep "^\- \[ \]"

# Check TODO.md Backlog for matching work
grep -i "{user_request_keywords}" TODO.md

# Check PLANS.md for active plans
grep -A 5 "^### \[" todo/PLANS.md | grep -i "{user_request_keywords}"
```

### Step 4: Auto-Select with Override Options

**If on `main` branch**, auto-select best match and offer override:

> On `main`. Creating worktree for `feature/{best-match-name}` (from {source}).
>
> [Enter] to confirm, or:
> 1. Use different name
> 2. Continue on `main` (docs-only, not recommended for code)

Where `{source}` is one of:
- "TODO.md" - matched a task
- "PLANS.md" - matched an active plan
- "your request" - derived from conversation

**Note**: Always use worktrees, not `git checkout -b`. The main repo directory must stay on `main`.

**If existing branch matches**, auto-select it:

> Found existing branch: `feature/user-auth` (3 days old, 5 commits ahead)
>
> [Enter] to continue on this branch, or:
> 1. Create new branch instead
> 2. Use different existing branch

**If already on a work branch**, just continue:

> Continuing on `feature/user-auth`.

### User Response Handling

- **Number**: Execute that option
- **"yes"/"y"**: Execute option 1 (default/recommended)
- **Custom text**: Interpret as branch name or clarification

## Issue URL Handling

When user pastes a GitHub/GitLab/Gitea issue URL:

### Supported URL Patterns

| Platform | Pattern | Example |
|----------|---------|---------|
| GitHub | `github.com/{owner}/{repo}/issues/{num}` | `https://github.com/user/repo/issues/123` |
| GitLab | `gitlab.com/{owner}/{repo}/-/issues/{num}` | `https://gitlab.com/user/repo/-/issues/45` |
| Gitea | `{domain}/{owner}/{repo}/issues/{num}` | `https://git.example.com/user/repo/issues/67` |
| Self-hosted | `git.{domain}/*` or `git*.{domain}/*` | `https://git.company.com/team/project/issues/89` |

### Issue Workflow

```bash
# 1. Parse URL to extract: platform, owner, repo, issue_number
# Example: https://github.com/acme/widget/issues/42

# 2. Check if repo exists locally
REPO_PATH=~/Git/{repo}
if [[ -d "$REPO_PATH" ]]; then
    cd "$REPO_PATH"
    git fetch origin
else
    # Clone to ~/Git/{repo}
    gh repo clone {owner}/{repo} "$REPO_PATH"  # GitHub
    # glab repo clone {owner}/{repo} "$REPO_PATH"  # GitLab
    cd "$REPO_PATH"
fi

# 3. Determine branch type from issue
# - "bug" label → bugfix/
# - "feature"/"enhancement" label → feature/
# - Default → feature/

# 4. Create branch
git checkout main && git pull origin main
git checkout -b {type}/{issue_number}-{slug-from-title}
# Example: feature/42-add-user-dashboard

# 5. Inform user
echo "Created branch {type}/{issue_number}-{slug} linked to issue #{issue_number}"
```

### Platform Detection

```bash
# Detect platform from URL
detect_git_platform() {
    local url="$1"
    if [[ "$url" == *"github.com"* ]]; then
        echo "github"
    elif [[ "$url" == *"gitlab.com"* ]]; then
        echo "gitlab"
    elif [[ "$url" == *"gitea"* ]] || [[ "$url" == *"/issues/"* ]]; then
        # Check if it's a Gitea instance
        echo "gitea"
    else
        # Self-hosted - try to detect
        echo "unknown"
    fi
}
```

## Repository Ownership Check

Before pushing or creating PRs, check ownership:

```bash
# Get remote URL
REMOTE_URL=$(git remote get-url origin)

# Extract owner from URL
# GitHub: git@github.com:owner/repo.git or https://github.com/owner/repo.git
REPO_OWNER=$(echo "$REMOTE_URL" | sed -E 's/.*[:/]([^/]+)\/[^/]+\.git$/\1/')

# Get current user
CURRENT_USER=$(gh api user --jq '.login')  # GitHub
# CURRENT_USER=$(glab api user --jq '.username')  # GitLab

# Check if owner
if [[ "$REPO_OWNER" != "$CURRENT_USER" ]]; then
    echo "NON_OWNER: Fork workflow required"
fi
```

**If non-owner**: See `workflows/pr.md` for fork workflow.

## New Repository Initialization

For new empty repositories:

```bash
# 1. Initialize with main branch
git init
git checkout -b main

# 2. Create initial commit
echo "# Project Name" > README.md
git add README.md
git commit -m "chore: initial commit"

# 3. Suggest first release branch
echo "Repository initialized. For your first version, create:"
echo "  git checkout -b release/0.1.0"
```

### First Version Guidance

| Project State | Suggested Version | Branch |
|---------------|-------------------|--------|
| New project, no features | 0.1.0 | `release/0.1.0` |
| MVP ready | 1.0.0 | `release/1.0.0` |
| Existing project, first aidevops use | Current + patch | `release/X.Y.Z` |

## Branch Type Selection

When creating a branch, determine type from conversation context:

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
┌─────────────────────────────────────────────────────────────────────────────┐
│                         COMPLETE GIT WORKFLOW                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. CONVERSATION START                                                       │
│     ├── Detect git repo context                                              │
│     ├── Check current branch (warn if on main)                               │
│     ├── Check for existing WIP branches                                      │
│     └── Suggest/create appropriate branch                                    │
│         └── See: workflows/branch.md                                         │
│                                                                              │
│  2. DEVELOPMENT                                                              │
│     ├── Work on feature/bugfix/etc branch                                    │
│     ├── Regular commits with conventional format                             │
│     └── Keep branch updated with main                                        │
│         └── See: workflows/branch.md                                         │
│                                                                              │
│  3. PREFLIGHT (before push)                                                  │
│     ├── Run linters-local.sh                                                 │
│     ├── Validate code quality                                                │
│     └── Check for secrets                                                    │
│         └── See: workflows/preflight.md                                      │
│                                                                              │
│  4. PUSH & PR                                                                │
│     ├── Push branch to origin (or fork if non-owner)                         │
│     ├── Create PR/MR                                                         │
│     └── Run code-audit-remote                                                │
│         └── See: workflows/pr.md                                             │
│                                                                              │
│  5. REVIEW & MERGE                                                           │
│     ├── Address review feedback                                              │
│     ├── Squash merge to main                                                 │
│     └── Delete feature branch                                                │
│         └── See: workflows/pr.md                                             │
│                                                                              │
│  6. RELEASE PREPARATION (when ready)                                         │
│     ├── Create release/X.Y.Z branch                                          │
│     ├── Select branches to include                                           │
│     ├── Update version files                                                 │
│     └── Generate changelog                                                   │
│         └── See: workflows/version-bump.md                                   │
│                                                                              │
│  7. RELEASE                                                                  │
│     ├── Merge release branch to main                                         │
│     ├── Tag main with vX.Y.Z                                                 │
│     ├── Create GitHub/GitLab release                                         │
│     └── Delete release branch                                                │
│         └── See: workflows/release.md                                        │
│                                                                              │
│  8. POSTFLIGHT                                                               │
│     ├── Verify CI/CD passes                                                  │
│     ├── Check quality gates                                                  │
│     └── Offer cleanup of merged branches                                     │
│         └── See: workflows/postflight.md                                     │
│                                                                              │
│  9. CLEANUP                                                                  │
│     ├── Delete merged branches (local + remote)                              │
│     ├── Prune stale remote refs                                              │
│     └── Update local main                                                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Post-Change Workflow

After completing file changes, run preflight automatically:

> Running preflight checks...

**If preflight passes**, auto-commit with suggested message:

> Preflight passed. Committing: "{suggested message}"
>
> [Enter] to confirm, or:
> 1. Use different message
> 2. Make more changes first

**If preflight fails**, show issues and offer fixes:

> Preflight found {N} issues:
> - {issue 1}
> - {issue 2}
>
> 1. Fix automatically (if possible)
> 2. View detailed report
> 3. Skip and commit anyway (not recommended)

**After successful commit**, auto-push if on a branch:

> Committed and pushed to `{branch}`.
>
> 1. Create PR
> 2. Continue working
> 3. Done for now

**If changes include `.agents/` files** (in aidevops repo or repos with local agents):

> Agent files modified. Run `./setup.sh` to deploy to `~/.aidevops/agents/`?
>
> 1. Run setup.sh now (recommended)
> 2. Remind me after merge
> 3. Skip (I'll do it manually)

This ensures the deployed agents at `~/.aidevops/agents/` stay in sync with source.

## Branch Cleanup

After merge and successful postflight:

```bash
# 1. Switch to main and update
git checkout main
git pull origin main

# 2. List merged branches
git branch --merged main | grep -vE "^\*|main|develop"

# 3. Delete merged branches (with confirmation)
# For each branch:
git branch -d {branch-name}           # Local
git push origin --delete {branch-name} # Remote (if not auto-deleted)

# 4. Prune stale remote refs
git remote prune origin
```

### Cleanup Decision Tree

| Branch State | Action |
|--------------|--------|
| Merged + postflight passed | Safe to delete |
| Merged + postflight failed | Keep, may need hotfix |
| Unmerged + stale (>30 days) | Ask user about status |
| Unmerged + active | Keep |

## User Experience Levels

These workflows support all skill levels:

### New Developers (Vibe-Coders)

- AI handles branch creation automatically
- Clear explanations of why branching matters
- Guided through PR process
- Protected from common mistakes

### Experienced Developers

- Can override suggestions when needed
- Familiar patterns (GitFlow-inspired)
- Efficient commands without excessive prompts
- Full control when requested

### Team Collaboration

- Consistent branch naming across team
- Clear PR descriptions for reviewers
- Traceable history for debugging
- Easy handoff between developers

## Override Handling

When user wants to work directly on main:

```text
User: "Just make the change on main, I know what I'm doing"

AI: "Understood. I'll proceed on main. Note that without a branch:
- Changes are harder to rollback
- No PR review before merge
- Harder to collaborate or get help

Proceeding with changes on main..."
```

**Never block** the user - these are guidelines, not restrictions.

## Database Schema Changes

When changes include database schema modifications:

### Detection

Look for:
- Files in `schemas/` (declarative schema files)
- Files in `migrations/`, `database/migrations/`, or similar
- SQL files with schema changes (`CREATE TABLE`, `ALTER TABLE`, etc.)
- ORM schema files (Drizzle `.ts`, Prisma `.prisma`, etc.)

### Declarative Schema Workflow (Recommended)

When `schemas/` directory exists (created by `aidevops init database`):

1. **Edit schema files** in `schemas/`
2. **Generate migration** via diff command:
   - Supabase: `supabase db diff -f description`
   - Drizzle: `npx drizzle-kit generate`
   - Atlas: `atlas migrate diff description`
   - Prisma: `npx prisma migrate dev --name description`
3. **Review generated migration** in `migrations/`
4. **Apply migration** locally
5. **Commit both** schema and migration files together

### Branch Naming for Migrations

| Change Type | Branch | Example |
|-------------|--------|---------|
| New table | `feature/` | `feature/add-user-preferences-table` |
| Schema fix | `bugfix/` | `bugfix/fix-orders-foreign-key` |
| Data backfill | `chore/` | `chore/backfill-user-status` |

### Pre-Push Checklist for Migrations

Before pushing migration files:

1. ✅ Schema file updated (if using declarative approach)
2. ✅ Migration generated via diff (not written manually)
3. ✅ Migration reviewed for unexpected changes
4. ✅ Tested locally (apply, rollback, apply again)
5. ✅ No modifications to already-pushed migrations
6. ✅ Timestamp is current (regenerate if rebasing)

### Critical Rules

- **NEVER modify migrations that have been pushed/deployed.** Create a new migration to fix issues.
- **ALWAYS commit schema and migration files together** to keep them in sync.
- **ALWAYS review generated migrations** before committing.

See `workflows/sql-migrations.md` for full migration workflow.

## Destructive Command Safety Hooks

Claude Code users get automatic protection against destructive git and filesystem
commands via a `PreToolUse` hook. The hook intercepts Bash commands before execution
and blocks dangerous patterns.

### What Gets Blocked

| Command | Risk |
|---------|------|
| `git checkout -- <files>` | Discards uncommitted changes |
| `git restore <files>` | Same as checkout (newer syntax) |
| `git reset --hard` | Destroys all uncommitted work |
| `git clean -f` | Removes untracked files permanently |
| `git push --force` / `-f` | Overwrites remote history |
| `git branch -D` | Force-deletes without merge check |
| `rm -rf` (non-temp paths) | Recursive deletion |
| `git stash drop` / `clear` | Permanently deletes stashes |

### What Stays Allowed

| Command | Why |
|---------|-----|
| `git checkout -b <branch>` | Creates new branch |
| `git restore --staged` | Only unstages, safe |
| `git clean -n` / `--dry-run` | Preview only |
| `rm -rf /tmp/...` | Temp directories |
| `git push --force-with-lease` | Safe force push |
| `git branch -d` | Checks merge status first |

### Installation

```bash
# Automatic (runs during setup.sh)
aidevops update

# Manual
~/.aidevops/agents/scripts/install-hooks.sh          # Global (~/.claude/)
~/.aidevops/agents/scripts/install-hooks.sh --project # Current project only
~/.aidevops/agents/scripts/install-hooks.sh --test    # Run self-test
~/.aidevops/agents/scripts/install-hooks.sh --uninstall
```

Requires Python 3 and Claude Code. Restart Claude Code after installation.

### How It Works

The hook runs as a `PreToolUse` handler on the `Bash` tool. Claude Code sends
the command as JSON on stdin. The guard checks against destructive regex patterns,
returns a `deny` decision if matched, and the command never executes.

Files: `~/.aidevops/agents/hooks/git_safety_guard.py` (guard script),
`~/.claude/settings.json` (hook configuration).

### Limitations

- Regex-based pattern matching; obfuscated commands may bypass it
- This is a safety net for honest mistakes, not a security boundary
- OpenCode does not currently support hooks (protection is instruction-based only)

## Related Workflows

| Workflow | When to Read |
|----------|--------------|
| `branch.md` | Branch naming, creation, lifecycle |
| `branch/release.md` | Release branch specifics |
| `pr.md` | PR creation, review, merge, fork workflow |
| `preflight.md` | Quality checks before push |
| `postflight.md` | Verification after release |
| `version-bump.md` | Version management, release branches |
| `release.md` | Full release process |
| `feature-development.md` | Feature implementation patterns |
| `bug-fixing.md` | Bug fix patterns |
| `sql-migrations.md` | Database schema version control |

## Platform CLI Reference

| Platform | CLI | Branch | PR | Release |
|----------|-----|--------|-----|---------|
| GitHub | `gh` | `git checkout -b` | `gh pr create` | `gh release create` |
| GitLab | `glab` | `git checkout -b` | `glab mr create` | `glab release create` |
| Gitea | `tea` | `git checkout -b` | `tea pulls create` | `tea releases create` |

See `tools/git.md` for detailed CLI usage.
