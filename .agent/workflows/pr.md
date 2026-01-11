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
```text

**Quick Commands**:

| Platform | Create | Review | Merge |
|----------|--------|--------|-------|
| GitHub | `gh pr create --fill` | `/pr review` | `gh pr merge --squash` |
| GitLab | `glab mr create --fill` | `/pr review` | `glab mr merge --squash` |
| Gitea | `tea pulls create` | `/pr review` | `tea pulls merge` |

<!-- AI-CONTEXT-END -->

## Purpose

The `/pr` command is the unified entry point for PR review that:

1. **Orchestrates all quality checks** - Runs local linters, remote audits, and standards checks
2. **Analyzes intent vs reality** - Compares PR description to actual code changes
3. **Detects undocumented changes** - Flags modifications not mentioned in PR description
4. **Provides actionable summary** - Clear pass/fail with specific recommendations

## Workflow Position

```text
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│ branch.md   │────►│      pr.md       │────►│ release.md  │
│             │     │                  │     │             │
│ - Create    │     │ - Orchestrate    │     │ - Tag       │
│ - Develop   │     │ - Lint local     │     │ - Changelog │
│ - Commit    │     │ - Audit remote   │     │ - Publish   │
│             │     │ - Check standards│     │             │
│             │     │ - Intent vs Real │     │             │
│             │     │ - Merge          │     │             │
└─────────────┘     └──────────────────┘     └─────────────┘
```text

## Orchestrated Checks

### 1. Local Linting (`/linters-local`)

Runs fast, offline checks using local tools:

```bash
# Executed by /linters-local
~/.aidevops/agents/scripts/linters-local.sh
```text

**Checks**:
- ShellCheck for shell scripts
- Secretlint for exposed secrets
- Pattern validation (return statements, positional parameters)
- Markdown formatting

### 2. Remote Auditing (`/code-audit-remote`)

Calls remote quality services via APIs:

```bash
# Executed by /code-audit-remote
~/.aidevops/agents/scripts/code-audit-helper.sh audit [repo]
```text

**Services**:
- CodeRabbit - AI-powered code review
- Codacy - Code quality analysis
- SonarCloud - Security and maintainability

### 3. Standards Compliance (`/code-standards`)

Checks against our documented quality standards:

**Reference**: `tools/code-review/code-standards.md`

**Standards**:
- S7679: Positional parameters assigned to local variables
- S7682: Explicit return statements in functions
- S1192: Constants for repeated strings
- S1481: No unused variables

## Usage

### Review a PR

```bash
# Review current branch's PR
/pr review

# Review specific PR by number
/pr review 123

# Review PR by URL
/pr review https://github.com/user/repo/pull/123
```text

### Create a PR with Pre-checks

```bash
# Create PR after running all checks
/pr create

# Create draft PR
/pr create --draft
```text

### Full Workflow

```bash
# 1. Push branch
git push -u origin HEAD

# 2. Run comprehensive review
/pr review

# 3. Create PR if checks pass
/pr create --fill

# 4. After approval, merge
gh pr merge --squash --delete-branch
```text

## Output Format

The `/pr` command produces a structured report:

```markdown
## PR Review: #123 - Add user authentication

### Quality Checks

**Local Linting** (`/linters-local`):
- ShellCheck: 0 violations
- Secretlint: 0 secrets detected
- Pattern checks: PASS

**Remote Audit** (`/code-audit-remote`):
- CodeRabbit: 2 suggestions (minor)
- SonarCloud: 1 code smell (S1192)
- Codacy: A-grade maintained

**Standards Compliance** (`/code-standards`):
- Return statements: PASS
- Positional parameters: PASS
- Error handling: PASS

### Intent vs Reality

**PR Description Claims**:
- Implements OAuth2 flow
- Adds session management
- Closes #123

**Code Analysis Confirms**:
| Claimed | Found In | Status |
|---------|----------|--------|
| OAuth2 flow | `auth/oauth.js` | Verified |
| Session management | `session/manager.js` | Verified |
| Closes #123 | Issue matches scope | Verified |

**Undocumented Changes Detected**:
- Modified `config/database.js` (not mentioned)
- Added dependency `lodash` (not documented)

### Recommendation

- [ ] Address 1 code smell before merge
- [ ] Document database config change in PR description
- [ ] Justify lodash dependency addition

**Overall**: CHANGES REQUESTED
```text

## Fork Workflow (Non-Owner Repositories)

When working on a repository you don't own, use the fork workflow:

### Detect Non-Owner Status

```bash
# Get remote URL and extract owner
REMOTE_URL=$(git remote get-url origin)
REPO_OWNER=$(echo "$REMOTE_URL" | sed -E 's/.*[:/]([^/]+)\/[^/]+\.git$/\1/')

# Get current user (GitHub)
CURRENT_USER=$(gh api user --jq '.login')

# Check if owner
if [[ "$REPO_OWNER" != "$CURRENT_USER" ]]; then
    echo "Fork workflow required"
fi
```text

### Fork and Setup

**GitHub:**

```bash
# 1. Fork the repository
gh repo fork {owner}/{repo} --clone=false

# 2. Add fork as remote
git remote add fork git@github.com:{your-username}/{repo}.git

# 3. Verify remotes
git remote -v
# origin    git@github.com:{owner}/{repo}.git (fetch/push) - upstream
# fork      git@github.com:{your-username}/{repo}.git (fetch/push) - your fork
```text

**GitLab:**

```bash
# 1. Fork via web UI or API
glab repo fork {owner}/{repo}

# 2. Add fork as remote
git remote add fork git@gitlab.com:{your-username}/{repo}.git
```text

**Gitea:**

```bash
# 1. Fork via web UI
# 2. Add fork as remote
git remote add fork git@{gitea-host}:{your-username}/{repo}.git
```text

### Push and Create PR to Upstream

```bash
# 1. Push to your fork
git push fork {branch-name}

# 2. Create PR to upstream (GitHub)
gh pr create --repo {owner}/{repo} --head {your-username}:{branch-name}

# GitLab equivalent
glab mr create --target-project {owner}/{repo} --source-branch {branch-name}
```text

### Keeping Fork Updated

```bash
# Fetch upstream changes
git fetch origin main

# Update your fork's main
git checkout main
git merge origin/main
git push fork main

# Rebase your feature branch
git checkout {branch-name}
git rebase main
git push fork {branch-name} --force-with-lease
```text

### Fork Workflow Diagram

```text
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Upstream Repo  │     │    Your Fork    │     │   Local Clone   │
│  (origin)       │     │    (fork)       │     │                 │
├─────────────────┤     ├─────────────────┤     ├─────────────────┤
│                 │     │                 │     │                 │
│  main ◄─────────┼─────┼─── PR ◄─────────┼─────┼─── push fork    │
│                 │     │                 │     │                 │
│                 │     │  {branch} ◄─────┼─────┼─── your work    │
│                 │     │                 │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```text

## Creating Pull Requests

### GitHub (`gh`)

```bash
# Push branch first
git push -u origin HEAD

# Create PR with auto-filled title/body from commits
gh pr create --fill

# Create PR with custom details
gh pr create \
  --title "feat: Add user authentication" \
  --body "## Summary
- Implements OAuth2 flow
- Adds session management

Closes #123"

# Create draft PR (not ready for review)
gh pr create --fill --draft

# Create PR and request reviewers
gh pr create --fill --reviewer @username,@team
```text

### GitLab (`glab`)

```bash
# Push branch first
git push -u origin HEAD

# Create MR with auto-filled details
glab mr create --fill

# Create draft MR
glab mr create --fill --draft

# Create MR and assign reviewers
glab mr create --fill --reviewer @username
```text

### Gitea (`tea`)

```bash
# Push branch first
git push -u origin HEAD

# Create PR
tea pulls create \
  --title "feat: Add user authentication" \
  --description "Summary of changes"
```text

## Merging Pull Requests

### Merge Strategies

| Strategy | Command | When to Use |
|----------|---------|-------------|
| **Squash** | `--squash` | Multiple commits -> single clean commit |
| **Merge** | `--merge` | Preserve full commit history |
| **Rebase** | `--rebase` | Linear history, no merge commits |

**Recommendation**: Use squash for feature branches to keep main history clean.

### GitHub

```bash
# Squash merge (recommended)
gh pr merge 123 --squash

# Auto-merge when checks pass
gh pr merge 123 --squash --auto

# Delete branch after merge
gh pr merge 123 --squash --delete-branch
```text

### GitLab

```bash
# Squash merge
glab mr merge 123 --squash

# Merge when pipeline succeeds
glab mr merge 123 --when-pipeline-succeeds
```text

## Task Status Updates

Workflow commands automatically update task status in TODO.md:

### Task Lifecycle

```text
Ready/Backlog → In Progress → In Review → Done
   (branch)       (develop)      (PR)     (merge/release)
```

### On PR Creation

Move task from `## In Progress` to `## In Review`:

```markdown
# Before (in ## In Progress)
- [ ] t001 Add user dashboard #feature ~4h started:2025-01-15T10:30Z

# After (move to ## In Review)
- [ ] t001 Add user dashboard #feature ~4h started:2025-01-15T10:30Z pr:123
```

```bash
# Sync with Beads after updating TODO.md
~/.aidevops/agents/scripts/beads-sync-helper.sh push
```

### On PR Merge

Move task from `## In Review` to `## Done`:

```markdown
# Before (in ## In Review)
- [ ] t001 Add user dashboard #feature ~4h started:2025-01-15T10:30Z pr:123

# After (move to ## Done)
- [x] t001 Add user dashboard #feature ~4h actual:5h started:2025-01-15T10:30Z completed:2025-01-16T14:00Z
```

```bash
# Sync with Beads after updating TODO.md
~/.aidevops/agents/scripts/beads-sync-helper.sh push
```

## Post-Merge Actions

After merging:

1. **Update task status** (see above):
   - Move task to `## Done`
   - Add `completed:` timestamp
   - Add `actual:` time if known
   - Sync with Beads

2. **Delete branch** (if not auto-deleted):

   ```bash
   git branch -d feature/xyz           # Local
   git push origin --delete feature/xyz # Remote
   ```

3. **Update local main**:

   ```bash
   git checkout main
   git pull origin main
   ```

4. **Create release** (if applicable):
   See `workflows/release.md`

## Troubleshooting

### PR Won't Merge

| Issue | Solution |
|-------|----------|
| Merge conflicts | `git merge main`, resolve conflicts, push |
| Checks failing | Fix issues, push new commits |
| Reviews pending | Request review or wait for approval |
| Branch protection | Ensure all requirements met |

### Resolving Merge Conflicts

```bash
git checkout main && git pull origin main
git checkout your-branch
git merge main
# Resolve conflicts in editor
git add . && git commit -m "fix: Resolve merge conflicts"
git push
```text

## Handling Contradictory AI Feedback

AI code reviewers (CodeRabbit, Codacy, etc.) may occasionally provide contradictory feedback. When this occurs:

### Detection

Contradictory feedback patterns:
- Reviewer suggests change A → B, then later suggests B → A
- Different reviewers suggest opposite changes
- Feedback contradicts documented standards or actual runtime behavior

### Resolution Process

1. **Verify actual behavior**: Test the code to confirm what works
   ```bash
   # Example: Verify application name works in AppleScript
   osascript -e 'tell application "iTerm" to get name'
   osascript -e 'tell application "iTerm2" to get name'
   ```

2. **Check authoritative sources**: Documentation, official APIs, standards

3. **Document your decision**: In PR comments, explain:
   - What the contradictory feedback was
   - How you verified the correct behavior
   - Why you're dismissing the feedback

4. **Proceed with merge**: If feedback is demonstrably incorrect, merge despite CHANGES_REQUESTED

   ```bash
   gh pr merge 123 --squash --delete-branch
   ```

### Example Comment

```markdown
Regarding the iTerm/iTerm2 naming: Both work in AppleScript. 
The app bundle is `/Applications/iTerm.app` but responds to both 
`tell application "iTerm"` and `tell application "iTerm2"`. 
Keeping current code - no change needed.
```

## Related Workflows

- **Branch creation**: `workflows/branch.md`
- **Local linting**: `scripts/linters-local.sh`
- **Remote auditing**: `workflows/code-audit-remote.md`
- **Standards reference**: `tools/code-review/code-standards.md`
- **Releases**: `workflows/release.md`
