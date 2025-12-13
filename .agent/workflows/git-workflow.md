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

**First Actions** (before any code changes):

```bash
# 1. Check current branch
git branch --show-current

# 2. Check repo ownership
git remote -v | head -1

# 3. Check for uncommitted work
git status --short
```

**Decision Tree**:

| Situation | Action |
|-----------|--------|
| On `main` branch | Suggest branch creation (see below) |
| On feature/bugfix branch | Continue, follow `branch.md` lifecycle |
| Issue URL pasted | Parse and create appropriate branch |
| Non-owner repo | Fork workflow (see `pr.md`) |
| New empty repo | Initialize with `main`, suggest `release/0.1.0` |

<!-- AI-CONTEXT-END -->

## Core Principle: Branch-First Development

Every code change should happen on a branch, enabling:

- **Safe parallel work** - Multiple developers without conflicts
- **Full traceability** - Every change linked to branch → PR → merge
- **Easy rollback** - Revert branches without affecting main
- **Code review** - PRs enable review before merge
- **Blame history** - Track who did what, when, and why

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

### Step 3: Present Options to User

**If on `main` branch**, present numbered options:

> I notice we're on `main`. For file changes, I recommend using a branch.
>
> **Existing branches that might be relevant:**
> 1. `feature/user-auth` (3 days old, 5 commits ahead)
> 2. `bugfix/login-timeout` (1 week old, 2 commits ahead)
>
> **Or create new:**
> 3. Create `feature/{suggested-name}` (recommended)
> 4. Create `bugfix/{suggested-name}`
> 5. Continue on `main` (not recommended - harder to rollback)
>
> Which option? (1-5)

**If no existing branches match**, simpler prompt:

> I notice we're on `main`. For this work, I suggest creating:
>
> `feature/{suggested-name}`
>
> 1. Yes, create this branch
> 2. Use different name (specify)
> 3. Continue on `main` (not recommended)
>
> Which option? (1-3)

**If already on a work branch**, confirm and continue:

> You're on `feature/user-auth`. Continue working on this branch?
>
> 1. Yes, continue here
> 2. Switch to different branch
> 3. Create new branch from main
>
> Which option? (1-3)

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

After completing file changes, always offer preflight before commit:

> I've completed the changes. Before committing:
>
> 1. Run preflight checks (recommended)
> 2. Skip preflight and commit directly
> 3. Continue making more changes
>
> Which option? (1-3)

**If preflight passes**, then offer commit:

> Preflight passed. Ready to commit:
>
> 1. Commit with message: "{suggested message}"
> 2. Commit with different message
> 3. Make more changes first
>
> Which option? (1-3)

**If preflight fails**, do NOT offer commit directly:

> Preflight found issues:
> - {issue 1}
> - {issue 2}
>
> 1. Fix these issues
> 2. View detailed report
> 3. Skip preflight and commit anyway (not recommended)
>
> Which option? (1-3)

**After successful commit**, offer push if on a branch:

> Committed. Next steps:
>
> 1. Push to remote
> 2. Make more changes first
> 3. Done for now
>
> Which option? (1-3)

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

## Platform CLI Reference

| Platform | CLI | Branch | PR | Release |
|----------|-----|--------|-----|---------|
| GitHub | `gh` | `git checkout -b` | `gh pr create` | `gh release create` |
| GitLab | `glab` | `git checkout -b` | `glab mr create` | `glab release create` |
| Gitea | `tea` | `git checkout -b` | `tea pulls create` | `tea releases create` |

See `tools/git.md` for detailed CLI usage.
