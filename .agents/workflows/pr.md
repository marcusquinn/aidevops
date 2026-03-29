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

**Orchestration Flow**:

```text
/pr [PR-URL or branch]
 ├── /linters-local      → ShellCheck, secretlint, pattern checks
 ├── /code-audit-remote  → CodeRabbit, Codacy, SonarCloud APIs
 ├── /code-standards     → Check against documented standards
 └── Summary: Intent vs Reality analysis
```

| Platform | Create | Review | Merge |
|----------|--------|--------|-------|
| GitHub | `gh pr create --fill` | `/pr review` | `gh pr merge --squash` |
| GitLab | `glab mr create --fill` | `/pr review` | `glab mr merge --squash` |
| Gitea | `tea pulls create` | `/pr review` | `tea pulls merge` |

<!-- AI-CONTEXT-END -->

## Usage

```bash
/pr review                                          # Current branch's PR
/pr review 123                                      # By number
/pr review https://github.com/user/repo/pull/123    # By URL
/pr create [--draft]                                # Create after checks
```

## Creating Pull Requests

```bash
# GitHub
git push -u origin HEAD
gh pr create --fill                                    # Auto-fill from commits
gh pr create --title "feat: ..." --body "Closes #123"  # Custom title/body
gh pr create --fill --draft                            # Draft PR
gh pr create --fill --reviewer @username,@team         # With reviewers
# GitLab: glab mr create --fill  |  Gitea: tea pulls create --title "feat: ..."
```

## Merging Pull Requests

| Strategy | Flag | When |
|----------|------|------|
| Squash | `--squash` | Multiple commits -> single clean commit (recommended) |
| Merge | `--merge` | Preserve full commit history |
| Rebase | `--rebase` | Linear history, no merge commits |

### Pre-Merge: Review Bot Gate (t1382)

```bash
~/.aidevops/agents/scripts/review-bot-gate-helper.sh check 123   # PASS/WAITING/SKIP
~/.aidevops/agents/scripts/review-bot-gate-helper.sh wait 123    # Wait up to 10 min
~/.aidevops/agents/scripts/review-bot-gate-helper.sh list 123    # List bot activity
```

Add `skip-review-gate` label to bypass for docs-only PRs or repos without bots.

**Merge**: `gh pr merge 123 --squash [--auto] [--delete-branch]` | GitLab: `glab mr merge 123 --squash [--when-pipeline-succeeds]`

## Orchestrated Checks

### 1. Local Linting (`/linters-local`)

Run `~/.aidevops/agents/scripts/linters-local.sh` — ShellCheck, secretlint, pattern validation (return statements, positional parameters), markdown formatting.

### 2. Remote Auditing (`/code-audit-remote`)

Run `~/.aidevops/agents/scripts/code-audit-helper.sh audit [repo]` — CodeRabbit (AI review), Codacy (quality), SonarCloud (security/maintainability). Monitored AI reviewers: `coderabbit*`, `gemini-code-assist[bot]`, `augment-code[bot]`/`augmentcode[bot]`, `copilot[bot]`.

### 3. Standards Compliance (`/code-standards`)

Reference: `tools/code-review/code-standards.md`. Standards: S7679 (positional params -> local vars), S7682 (explicit returns), S1192 (constants for repeated strings), S1481 (no unused vars).

## Output Format

Report structure: `## PR Review: #NNN - Title` with sections: **Quality Checks** (local linting counts, remote audit results, standards pass/fail), **Intent vs Reality** (table: Claimed | Found In | Status — flag undocumented changes), **Recommendation** (action items, overall APPROVE / CHANGES REQUESTED).

## Loop Commands

| Command | Purpose | Default Limit |
|---------|---------|---------------|
| `/pr-loop` | Iterate until PR approved/merged | 10 iterations |
| `/preflight-loop` | Iterate until preflight passes | 5 iterations |

**Timeout recovery**: `gh pr view --json state,reviewDecision,statusCheckRollup`, then `/pr review` (single cycle) or `/pr-loop` (restart loop).

## Post-Merge Actions

1. Add `pr:NNN` to task line, move to `## In Review`; on merge mark `[x]`, add `completed:` timestamp, move to `## Done`
2. Sync: `~/.aidevops/agents/scripts/beads-sync-helper.sh push`
3. Delete branch: `git branch -d feature/xyz && git push origin --delete feature/xyz`
4. Update local main: `git checkout main && git pull origin main`
5. Create release if applicable: see `workflows/release.md`

## Fork Workflow (Non-Owner Repositories)

**Detect**: Compare `git remote get-url origin` owner against `gh api user --jq '.login'`. Mismatch = fork workflow.

```bash
# GitHub fork setup
gh repo fork {owner}/{repo} --clone=false
git remote add fork git@github.com:{your-username}/{repo}.git
git push fork {branch-name}
gh pr create --repo {owner}/{repo} --head {your-username}:{branch-name}

# GitLab fork setup
glab repo fork {owner}/{repo}
git remote add fork git@gitlab.com:{your-username}/{repo}.git
glab mr create --target-project {owner}/{repo} --source-branch {branch-name}

# Keep fork updated
git fetch origin main && git checkout main && git merge origin/main && git push fork main
git checkout {branch-name} && git rebase main && git push fork {branch-name} --force-with-lease
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Merge conflicts | `git merge main`, resolve, `git add && git commit && git push`. See `tools/git/conflict-resolution.md` |
| Branch protection | Ensure all requirements met |

## Handling Contradictory AI Feedback

When reviewers suggest opposite changes or contradict documented standards: (1) verify actual behavior by testing, (2) check authoritative sources (docs, APIs, standards), (3) document your decision in PR comments (what contradicted, how verified, why dismissing), (4) proceed with merge if feedback is demonstrably incorrect.

## Related Workflows

- **Branch creation**: `workflows/branch.md`
- **Remote auditing**: `workflows/code-audit-remote.md`
- **Standards reference**: `tools/code-review/code-standards.md`
- **Releases**: `workflows/release.md`
- **Conflict resolution**: `tools/git/conflict-resolution.md`
