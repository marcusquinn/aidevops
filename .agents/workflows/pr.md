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

**Monitored AI reviewers**:

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
/pr review 123       # Review by number
/pr review https://github.com/user/repo/pull/123

/pr create           # Create PR after running all checks
/pr create --draft
```

**Full workflow**:

```bash
git push -u origin HEAD
/pr review
/pr create --fill
gh pr merge --squash --delete-branch
```

## Output Format

```markdown
## PR Review: #123 - Add user authentication

### Quality Checks
**Local Linting**: ShellCheck 0 violations | Secretlint 0 secrets | Pattern checks PASS
**Remote Audit**: CodeRabbit 2 suggestions (minor) | SonarCloud 1 code smell (S1192) | Codacy A-grade
**Standards**: Return statements PASS | Positional parameters PASS | Error handling PASS

### Intent vs Reality
| Claimed | Found In | Status |
|---------|----------|--------|
| OAuth2 flow | `auth/oauth.js` | Verified |
| Session management | `session/manager.js` | Verified |

**Undocumented Changes**: Modified `config/database.js` (not mentioned); added `lodash` dependency

### Recommendation
- [ ] Address 1 code smell before merge
- [ ] Document database config change in PR description

**Overall**: CHANGES REQUESTED
```

## Loop Commands

| Command | Purpose | Default Limit |
|---------|---------|---------------|
| `/pr-loop` | Iterate until PR approved/merged | 10 iterations |
| `/preflight-loop` | Iterate until preflight passes | 5 iterations |

**Timeout recovery**:

```bash
gh pr view --json state,reviewDecision,statusCheckRollup
/pr review    # Re-run single cycle
/pr-loop      # Restart loop if multiple issues remain
```

## Fork Workflow (Non-Owner Repositories)

**Detect non-owner status**:

```bash
REPO_OWNER=$(git remote get-url origin | sed -E 's/.*[:/]([^/]+)\/[^/]+\.git$/\1/')
CURRENT_USER=$(gh api user --jq '.login')
[[ "$REPO_OWNER" != "$CURRENT_USER" ]] && echo "Fork workflow required"
```

**Setup and push**:

```bash
# GitHub
gh repo fork {owner}/{repo} --clone=false
git remote add fork git@github.com:{your-username}/{repo}.git
git push fork {branch-name}
gh pr create --repo {owner}/{repo} --head {your-username}:{branch-name}

# GitLab
glab repo fork {owner}/{repo}
git remote add fork git@gitlab.com:{your-username}/{repo}.git
glab mr create --target-project {owner}/{repo} --source-branch {branch-name}
```

**Keep fork updated**:

```bash
git fetch origin main && git checkout main && git merge origin/main && git push fork main
git checkout {branch-name} && git rebase main && git push fork {branch-name} --force-with-lease
```

## Creating Pull Requests

```bash
# GitHub
git push -u origin HEAD
gh pr create --fill
gh pr create --title "feat: Add user authentication" --body "## Summary
- Implements OAuth2 flow
Closes #123"
gh pr create --fill --draft
gh pr create --fill --reviewer @username,@team

# GitLab
git push -u origin HEAD && glab mr create --fill

# Gitea
git push -u origin HEAD && tea pulls create --title "feat: ..." --description "..."
```

## Merging Pull Requests

| Strategy | Command | When to Use |
|----------|---------|-------------|
| Squash | `--squash` | Multiple commits → single clean commit (recommended) |
| Merge | `--merge` | Preserve full commit history |
| Rebase | `--rebase` | Linear history, no merge commits |

### Pre-Merge: Review Bot Gate (t1382)

```bash
~/.aidevops/agents/scripts/review-bot-gate-helper.sh check 123   # PASS/WAITING/SKIP
~/.aidevops/agents/scripts/review-bot-gate-helper.sh wait 123    # Wait up to 10 min
~/.aidevops/agents/scripts/review-bot-gate-helper.sh list 123    # List bot activity
```

Add `skip-review-gate` label to bypass for docs-only PRs or repos without bots.

```bash
# GitHub
gh pr merge 123 --squash
gh pr merge 123 --squash --auto
gh pr merge 123 --squash --delete-branch

# GitLab
glab mr merge 123 --squash
glab mr merge 123 --when-pipeline-succeeds
```

## Task Status Updates

```text
Ready/Backlog → In Progress → In Review → Done
   (branch)       (develop)      (PR)     (merge/release)
```

On PR creation — add `pr:NNN` to task line and move to `## In Review`.
On PR merge — mark `[x]`, add `completed:` timestamp, move to `## Done`.

```bash
~/.aidevops/agents/scripts/beads-sync-helper.sh push  # Sync after TODO.md updates
```

## Post-Merge Actions

1. Move task to `## Done` with `completed:` and `actual:` timestamps; sync Beads
2. Delete branch: `git branch -d feature/xyz && git push origin --delete feature/xyz`
3. Update local main: `git checkout main && git pull origin main`
4. Create release if applicable: see `workflows/release.md`

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Merge conflicts | `git merge main`, resolve, push |
| Checks failing | Fix issues, push new commits |
| Reviews pending | Request review or wait |
| Branch protection | Ensure all requirements met |

```bash
# Resolve conflicts
git checkout main && git pull origin main
git checkout your-branch && git merge main
# Resolve conflicts — see tools/git/conflict-resolution.md
git add <resolved-files> && git commit -m "fix: resolve merge conflicts" && git push
```

## Handling Contradictory AI Feedback

When reviewers suggest opposite changes or contradict documented standards:

1. **Verify actual behavior**: Test the code
2. **Check authoritative sources**: Docs, official APIs, standards
3. **Document your decision** in PR comments (what was contradictory, how you verified, why dismissing)
4. **Proceed with merge** if feedback is demonstrably incorrect: `gh pr merge 123 --squash --delete-branch`

## Related Workflows

- **Branch creation**: `workflows/branch.md`
- **Local linting**: `scripts/linters-local.sh`
- **Remote auditing**: `workflows/code-audit-remote.md`
- **Standards reference**: `tools/code-review/code-standards.md`
- **Releases**: `workflows/release.md`
- **Conflict resolution**: `tools/git/conflict-resolution.md`
