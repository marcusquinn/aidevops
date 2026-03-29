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
git branch --show-current  # If result is `main` → STOP
```

If on `main`: STOP. Present branch options before proceeding.

**First Actions** (before any code changes):

```bash
git fetch origin                   # Parallel session safety
git status --short                 # Check for uncommitted work
git log --oneline HEAD..origin/$(git branch --show-current) 2>/dev/null
```

Remote has new commits → pull/rebase first. Uncommitted local changes → stash or commit first.

**Worktrees** (DEFAULT for all feature work):

Main repo (`~/Git/{repo}/`) ALWAYS stays on `main`. All work in worktree directories.

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/
```

Non-git artifacts (`.venv/`, `node_modules/`, `dist/`, `.env`) don't transfer between worktrees — recreate in each. See `workflows/worktree.md` for full worktree workflow, `tools/code-review/code-standards.md` for Python packaging rules.

**Session-Branch Tracking**: After creating a branch, call `session-rename_sync_branch` to sync session name.

**Scope Monitoring**: When work evolves significantly from branch name/purpose, offer to create a new branch, continue on current, or stash and switch.

<!-- AI-CONTEXT-END -->

## Decision Tree

| Situation | Action |
|-----------|--------|
| On `main` branch | Create worktree — see `branch.md` for type selection |
| On feature/bugfix branch | Continue, follow `branch.md` lifecycle |
| Issue URL pasted | Parse and create appropriate branch (see Issue URL Handling) |
| Non-owner repo | Fork workflow — see `pr.md` |
| New empty repo | `git init && git checkout -b main`; suggest `release/0.1.0` (new), `release/1.0.0` (MVP), or `release/X.Y.Z` (existing adopting aidevops) |

## Time Tracking Integration

Record timestamps in TODO.md or PLANS.md. **Worker restriction**: Headless workers must NOT edit TODO.md — supervisor handles updates. See `workflows/plans.md`.

| Event | Field |
|-------|-------|
| Branch created | `started:` |
| Work session ends | `logged:` (cumulative) |
| PR merged | `completed:` |
| Release published | `actual:` |

## Branch Naming from Planning Files

```bash
grep -i "{keyword}" TODO.md todo/PLANS.md
ls todo/tasks/*{keyword}* 2>/dev/null
```

| Source | Pattern | Example |
|--------|---------|---------|
| TODO.md task | `{type}/{slugified-description}` | `feature/add-ahrefs-mcp-server` |
| PLANS.md entry | `{type}/{plan-slug}` | `feature/user-authentication-overhaul` |
| PRD file | `{type}/{prd-feature-name}` | `feature/export-csv` |

Slugification: lowercase, hyphens for spaces, remove special chars, truncate to ~50 chars. Branch type selection: see `branch.md`.

## Issue URL Handling

Parse issue URLs to extract platform, owner, repo, and issue number, then create a worktree:

```bash
# Clone if not local: gh repo clone {owner}/{repo} ~/Git/{repo}
git checkout main && git pull origin main
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add {type}/{issue_number}-{slug-from-title}
```

Supported: `github.com/{owner}/{repo}/issues/{num}`, `gitlab.com/{owner}/{repo}/-/issues/{num}`, `{domain}/{owner}/{repo}/issues/{num}` (Gitea).

**Repository ownership**: If `git remote get-url origin` owner differs from `gh api user --jq '.login'`, use fork workflow — see `workflows/pr.md`.

## Destructive Command Safety Hooks

Claude Code PreToolUse hooks block destructive git/filesystem commands before execution.

**Blocked**: `git checkout -- <files>`, `git restore <files>`, `git reset --hard`, `git clean -f`, `git push --force`/`-f`, `git branch -D`, `rm -rf` (non-temp), `git stash drop/clear`.

**Safe (allowlisted)**: `git checkout -b`, `git restore --staged`, `git clean -n`/`--dry-run`, `rm -rf /tmp/...`, `git push --force-with-lease`.

```bash
install-hooks-helper.sh status    # Check status
install-hooks-helper.sh install   # Reinstall
install-hooks-helper.sh test      # Run self-test (20 test cases)
install-hooks-helper.sh uninstall # Remove
```

Files: `~/.aidevops/hooks/git_safety_guard.py` (guard), `~/.claude/settings.json` (config). Installed by `setup.sh`. Requires Python 3 + Claude Code restart.

**Limitations**: Regex-based; obfuscated commands may bypass. Safety net for honest mistakes, not a security boundary.

## Post-Change Workflow

After file changes: run preflight automatically. Pass → auto-commit with suggested message (confirm or override). Fail → show issues, offer fixes. After commit → auto-push, offer: create PR, continue working, or done.

**PR Title (MANDATORY)**: `{task-id}: {description}`. Task ID is `tNNN` (from TODO.md) or `GH#NNN` (GitHub issue number, for quality-debt/simplification-debt/issue-only work). Examples: `t318: Update PR workflow documentation`, `GH#12455: tighten hashline-edit-format.md`. NEVER use `qd-`, bare numbers, or invented prefixes like `t12345` (that conflates GitHub issue numbers with the `t` task-ID system). For unplanned work: create TODO entry first. Every code change must be traceable to a task.

**If changes include `.agents/` files**: Offer to run `./setup.sh` to deploy to `~/.aidevops/agents/`.

## Branch Cleanup

```bash
git checkout main && git pull origin main
git branch --merged main | grep -vE "^\*|main|develop"
git branch -d {branch-name}            # Local
git push origin --delete {branch-name} # Remote
git remote prune origin
```

Delete merged branches after postflight. Keep unmerged unless stale (>30 days) — ask user.

## Override Handling

When user wants to work directly on main, acknowledge and proceed — never block. Note trade-offs (harder rollback, no PR review, harder collaboration) and continue.

## Database Schema Changes

See `workflows/sql-migrations.md` for the full migration workflow.

**Critical rules**: Never modify pushed/deployed migrations — create new ones. Always commit schema + migration together. Always review generated migrations before committing.

Branch naming: `feature/add-{table}-table`, `bugfix/fix-{description}`, `chore/backfill-{description}`.

## Workflow Lifecycle

```text
1. CONVERSATION START → detect git context, check branch, suggest/create branch
2. DEVELOPMENT → work on branch, conventional commits, keep updated with main
3. PREFLIGHT → linters-local.sh, code quality, secret check
4. PUSH & PR → push branch, create PR/MR, run code-audit-remote
5. REVIEW & MERGE → address feedback, squash merge, delete feature branch
6. RELEASE PREPARATION → release/X.Y.Z branch, version files, changelog
7. RELEASE → merge to main, tag, GitHub release, delete release branch
8. POSTFLIGHT → verify CI/CD, quality gates, cleanup offer
9. CLEANUP → delete merged branches, prune stale refs, update local main
```

## Related Workflows

| Workflow | When to Read |
|----------|--------------|
| `branch.md` | Branch naming, type selection, creation, lifecycle |
| `worktree.md` | Worktree creation, management, cleanup |
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
