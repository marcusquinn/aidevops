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

```
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

## Purpose

The `/pr` command is the unified entry point for PR review that:

1. **Orchestrates all quality checks** - Runs local linters, remote audits, and standards checks
2. **Analyzes intent vs reality** - Compares PR description to actual code changes
3. **Detects undocumented changes** - Flags modifications not mentioned in PR description
4. **Provides actionable summary** - Clear pass/fail with specific recommendations

## Workflow Position

```
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
```

## Orchestrated Checks

### 1. Local Linting (`/linters-local`)

Runs fast, offline checks using local tools:

```bash
# Executed by /linters-local
~/.aidevops/agents/scripts/linters-local.sh
```

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
```

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
```

### Create a PR with Pre-checks

```bash
# Create PR after running all checks
/pr create

# Create draft PR
/pr create --draft
```

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
```

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
```

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
```

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
```

### Gitea (`tea`)

```bash
# Push branch first
git push -u origin HEAD

# Create PR
tea pulls create \
  --title "feat: Add user authentication" \
  --description "Summary of changes"
```

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
```

### GitLab

```bash
# Squash merge
glab mr merge 123 --squash

# Merge when pipeline succeeds
glab mr merge 123 --when-pipeline-succeeds
```

## Post-Merge Actions

After merging:

1. **Delete branch** (if not auto-deleted):

   ```bash
   git branch -d feature/xyz           # Local
   git push origin --delete feature/xyz # Remote
   ```

2. **Update local main**:

   ```bash
   git checkout main
   git pull origin main
   ```

3. **Create release** (if applicable):
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
```

## Related Workflows

- **Branch creation**: `workflows/branch.md`
- **Local linting**: `scripts/linters-local.sh`
- **Remote auditing**: `workflows/code-audit-remote.md`
- **Standards reference**: `tools/code-review/code-standards.md`
- **Releases**: `workflows/release.md`
