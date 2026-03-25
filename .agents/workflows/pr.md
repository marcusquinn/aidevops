---
description: Unified PR workflow - orchestrates linting, auditing, standards checks, and intent vs reality analysis
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# PR Workflow - Unified Review Orchestrator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Comprehensive PR review orchestrating all quality checks
- **Prerequisite**: Branch created per `workflows/branch.md`
- **Post-merge**: Tag releases per `workflows/release.md`

**Orchestration Flow**:

```text
/pr [PR-URL or branch]
 ├── /linters-local      → ShellCheck, secretlint, pattern checks
 ├── /code-audit-remote  → CodeRabbit, Codacy, SonarCloud APIs
 ├── /code-standards     → Check against documented standards
 └── Summary: Intent vs Reality analysis
```

**Quick Commands**:

| Platform | Create | Review | Merge |
|----------|--------|--------|-------|
| GitHub | `gh pr create --fill` | `/pr review` | `gh pr merge --squash` |
| GitLab | `glab mr create --fill` | `/pr review` | `glab mr merge --squash` |
| Gitea | `tea pulls create` | `/pr review` | `tea pulls merge` |

<!-- AI-CONTEXT-END -->

## Orchestrated Checks

### 1. Local Linting (`/linters-local`)

```bash
~/.aidevops/agents/scripts/linters-local.sh
```

Checks: ShellCheck, secretlint, pattern validation (return statements, positional parameters), markdown formatting.

### 2. Remote Auditing (`/code-audit-remote`)

```bash
~/.aidevops/agents/scripts/code-audit-helper.sh audit [repo]
```

Services: CodeRabbit (AI review), Codacy (quality analysis), SonarCloud (security/maintainability).

**AI Code Reviewers monitored**:

| Reviewer | Bot Username Pattern |
|----------|---------------------|
| CodeRabbit | `coderabbit*` |
| Gemini Code Assist | `gemini-code-assist[bot]` |
| Augment Code | `augment-code[bot]`, `augmentcode[bot]` |
| GitHub Copilot | `copilot[bot]` |

### 3. Standards Compliance (`/code-standards`)

Reference: `tools/code-review/code-standards.md`

Standards: S7679 (positional params → local vars), S7682 (explicit returns), S1192 (constants for repeated strings), S1481 (no unused vars).

## Usage

```bash
/pr review           # Review current branch's PR
/pr review 123       # Review specific PR by number
/pr create           # Create PR after running all checks
/pr create --draft   # Create draft PR
```

**Full Workflow**:

```bash
git push -u origin HEAD
/pr review
/pr create --fill
gh pr merge --squash --delete-branch
```

## Pre-Merge: Review Bot Gate (t1382)

Before merging, verify AI code review bots have posted. Enforced at three layers:

1. **CI check**: `.github/workflows/review-bot-gate.yml` — add as required status check
2. **Agent check**: `review-bot-gate-helper.sh check <PR> [REPO]` — returns PASS/WAITING/SKIP
3. **Agent rule**: `prompts/build.txt`

```bash
~/.aidevops/agents/scripts/review-bot-gate-helper.sh check 123
~/.aidevops/agents/scripts/review-bot-gate-helper.sh wait 123   # Wait up to 10 min
~/.aidevops/agents/scripts/review-bot-gate-helper.sh list 123   # List bot activity
```

Add `skip-review-gate` label to bypass for docs-only PRs or repos without bots.

## Merge Strategies

| Strategy | Command | When to Use |
|----------|---------|-------------|
| **Squash** | `--squash` | Multiple commits → single clean commit (recommended) |
| **Merge** | `--merge` | Preserve full commit history |
| **Rebase** | `--rebase` | Linear history, no merge commits |

```bash
# GitHub
gh pr merge 123 --squash
gh pr merge 123 --squash --auto          # Auto-merge when checks pass
gh pr merge 123 --squash --delete-branch

# GitLab
glab mr merge 123 --squash
glab mr merge 123 --when-pipeline-succeeds
```

## Fork Workflow (Non-Owner Repositories)

```bash
# Detect non-owner status
REPO_OWNER=$(git remote get-url origin | sed -E 's/.*[:/]([^/]+)\/[^/]+\.git$/\1/')
CURRENT_USER=$(gh api user --jq '.login')

# Fork and setup
gh repo fork {owner}/{repo} --clone=false
git remote add fork git@github.com:{your-username}/{repo}.git

# Push and create PR to upstream
git push fork {branch-name}
gh pr create --repo {owner}/{repo} --head {your-username}:{branch-name}

# Keep fork updated
git fetch origin main && git checkout main && git merge origin/main && git push fork main
git checkout {branch-name} && git rebase main && git push fork {branch-name} --force-with-lease
```

GitLab: `glab repo fork` / `glab mr create --target-project {owner}/{repo}`
Gitea: Fork via web UI, then `git remote add fork git@{gitea-host}:{your-username}/{repo}.git`

## Task Status Updates

```text
Ready/Backlog → In Progress → In Review → Done
   (branch)       (develop)      (PR)     (merge/release)
```

On PR creation — add `pr:NNN` to task in `## In Progress`, move to `## In Review`:
```
- [ ] t001 Add user dashboard #feature ~4h started:2025-01-15T10:30Z pr:123
```

On PR merge — move to `## Done`, add `completed:` and `actual:` timestamps, mark `[x]`.

```bash
~/.aidevops/agents/scripts/beads-sync-helper.sh push  # Sync after TODO.md updates
```

## Post-Merge Actions

1. Move task to `## Done` with `completed:` timestamp and `actual:` time
2. Delete branch: `git branch -d feature/xyz && git push origin --delete feature/xyz`
3. Update local main: `git checkout main && git pull origin main`
4. Create release if applicable: see `workflows/release.md`

## Loop Commands

| Command | Purpose | Default Limit |
|---------|---------|---------------|
| `/pr-loop` | Iterate until PR approved/merged | 10 iterations |
| `/preflight-loop` | Iterate until preflight passes | 5 iterations |

**Timeout Recovery**:

```bash
gh pr view --json state,reviewDecision,statusCheckRollup
/pr review    # Re-run single review cycle
/pr-loop      # Restart loop if multiple issues remain
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Merge conflicts | `git merge main`, resolve, push |
| Checks failing | Fix issues, push new commits |
| Reviews pending | Request review or wait |
| Branch protection | Ensure all requirements met |

```bash
# Resolve merge conflicts
git checkout main && git pull origin main
git checkout your-branch && git merge main
# Resolve conflicts — see tools/git/conflict-resolution.md
git add <resolved-files> && git commit -m "fix: resolve merge conflicts" && git push
```

## Handling Contradictory AI Feedback

When reviewers suggest opposite changes or feedback contradicts runtime behavior:

1. **Verify actual behavior**: Test the code directly
2. **Check authoritative sources**: Documentation, official APIs, standards
3. **Document your decision** in PR comments: what the contradiction was, how you verified, why you're dismissing
4. **Proceed with merge** if feedback is demonstrably incorrect: `gh pr merge 123 --squash --delete-branch`

Example: "Both `tell application "iTerm"` and `tell application "iTerm2"` work in AppleScript — verified with `osascript`. Keeping current code."

## Related Workflows

- **Branch creation**: `workflows/branch.md`
- **Local linting**: `scripts/linters-local.sh`
- **Remote auditing**: `workflows/code-audit-remote.md`
- **Standards reference**: `tools/code-review/code-standards.md`
- **Conflict resolution**: `tools/git/conflict-resolution.md`
- **Releases**: `workflows/release.md`
