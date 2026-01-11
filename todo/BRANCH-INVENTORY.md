# Branch Inventory

Generated: 2026-01-11

This document tracks all unmerged branches with work-in-progress. All branches have been pushed to remote for preservation.

## Summary

| Category | Count | Status |
|----------|-------|--------|
| Unmerged branches | 13 | All pushed to remote |
| Active worktrees | 2 | Clean (no uncommitted changes) |
| Local-only branches | 0 | All pushed |

## Unmerged Branches

### Ready to Review (Single Commit, Complete)

These branches have complete work ready for PR review:

| Branch | Commit | Description | Action |
|--------|--------|-------------|--------|
| `bugfix/sonarcloud-default-cases` | `fa58869` | Add missing default cases to case statements | Create PR |
| `chore/add-missing-opencode-commands` | `f617fc8` | Add missing OpenCode commands to generator | Create PR |
| `chore/agent-review-improvements` | `cdfdf16` | Implement agent-review improvements | Create PR |
| `chore/agents-md-progressive-disclosure` | `38b427a` | Improve AGENTS.md progressive disclosure | Create PR |
| `chore/loop-agents-readme-changelog` | `cb18a2a` | Add README and changelog guidance to loop agents | Create PR |
| `chore/strengthen-git-workflow-instructions` | `090ba39` | Strengthen git workflow instructions | Create PR |
| `chore/worktree-workflow` | `e9a774d` | Update branch creation to recommend worktrees | Create PR |
| `feature/mcp-includetools-support` | `ece326b` | Add mcp_requirements frontmatter convention | Create PR |

### Feature Branches (May Need More Work)

| Branch | Commit | Description | Notes |
|--------|--------|-------------|-------|
| `feature/beads-integration` | `dcc3f9b` | Integrate Beads task graph visualization | Related to t019 (completed differently) |
| `feature/domain-research-subagent` | `eb73a51` | Add domain-research subagent with THC/Reconeer APIs | New feature, needs review |
| `feature/loop-system-v2` | `b17ae11` | Implement v2 architecture with fresh context | Related to t051 (completed via different approach) |
| `feature/memory-auto-capture` | `531eb2c` | Prevent removal of unpushed branches | Contains worktree fix (may be merged already) |
| `feature/session-review-command` | Multiple | Add /session-review and /full-loop commands | 4 commits, needs review |

## Worktrees

| Directory | Branch | Status |
|-----------|--------|--------|
| `~/Git/aidevops-chore-loop-agents-readme-changelog` | `chore/loop-agents-readme-changelog` | Directory not found (stale reference) |
| `~/Git/aidevops-feature-memory-auto-capture` | `feature/memory-auto-capture` | Clean |

## Recommended Actions

### Immediate (This Session)

1. **Delete stale worktree reference**: `git worktree prune`
2. **Delete local branches that are on remote**: Safe to delete, can recreate from remote

### Next Session

1. **Review and merge simple chore branches** (8 branches):
   - Create PRs for each
   - Most are single-commit documentation/config improvements
   
2. **Evaluate feature branches** (5 branches):
   - `feature/beads-integration` - May be superseded by t019 completion
   - `feature/loop-system-v2` - May be superseded by t051 completion
   - `feature/domain-research-subagent` - New feature, review for inclusion
   - `feature/memory-auto-capture` - Check if worktree fix is already in main
   - `feature/session-review-command` - Review 4 commits for /session-review and /full-loop

### Cleanup Commands

```bash
# Prune stale worktree references
git worktree prune

# Delete local branches (safe - all on remote)
git branch -D bugfix/sonarcloud-default-cases
git branch -D chore/add-missing-opencode-commands
git branch -D chore/agent-review-improvements
git branch -D chore/agents-md-progressive-disclosure
git branch -D chore/loop-agents-readme-changelog
git branch -D chore/strengthen-git-workflow-instructions
git branch -D chore/worktree-workflow
git branch -D feature/beads-integration
git branch -D feature/domain-research-subagent
git branch -D feature/loop-system-v2
git branch -D feature/mcp-includetools-support
git branch -D feature/memory-auto-capture
git branch -D feature/session-review-command

# Recreate any branch from remote when needed
git checkout -b <branch> origin/<branch>
```

## Branch Details

### bugfix/sonarcloud-default-cases
- **Commit**: `fa58869 fix(sonarcloud): add missing default cases to case statements`
- **Purpose**: Fix SonarCloud warnings about missing default cases in switch/case statements
- **Status**: Ready for PR

### chore/add-missing-opencode-commands
- **Commit**: `f617fc8 chore: add missing OpenCode commands to generator`
- **Purpose**: Update generate-opencode-agents.sh with missing commands
- **Status**: Ready for PR

### chore/agent-review-improvements
- **Commit**: `cdfdf16 chore: implement agent-review improvements`
- **Purpose**: Improvements to agent-review.md based on feedback
- **Status**: Ready for PR

### chore/agents-md-progressive-disclosure
- **Commit**: `38b427a docs: improve AGENTS.md progressive disclosure with descriptive hints`
- **Purpose**: Better progressive disclosure in main AGENTS.md
- **Status**: Ready for PR

### chore/loop-agents-readme-changelog
- **Commit**: `cb18a2a docs(loops): add README and changelog guidance to loop agents`
- **Purpose**: Documentation for loop system
- **Status**: Ready for PR (may already be merged via #41)

### chore/strengthen-git-workflow-instructions
- **Commit**: `090ba39 docs: strengthen git workflow instructions with numbered options`
- **Purpose**: Clearer git workflow instructions
- **Status**: Ready for PR

### chore/worktree-workflow
- **Commit**: `e9a774d docs: update branch creation to recommend worktrees for parallel sessions`
- **Purpose**: Recommend worktrees as default for parallel work
- **Status**: Ready for PR

### feature/beads-integration
- **Commit**: `dcc3f9b feat: integrate Beads task graph visualization`
- **Purpose**: Beads integration for task visualization
- **Status**: May be superseded by t019 completion (different approach taken)

### feature/domain-research-subagent
- **Commit**: `eb73a51 feat(seo): add domain-research subagent with THC and Reconeer APIs`
- **Purpose**: DNS intelligence subagent
- **Status**: New feature, needs review

### feature/loop-system-v2
- **Commit**: `b17ae11 feat(loops): implement v2 architecture with fresh context per iteration`
- **Purpose**: Loop system v2 with fresh sessions
- **Status**: May be superseded by t051 completion (merged via #38)

### feature/mcp-includetools-support
- **Commit**: `ece326b docs(build-agent): add mcp_requirements frontmatter convention`
- **Purpose**: Document MCP tool filtering convention
- **Status**: Ready for PR

### feature/memory-auto-capture
- **Commit**: `531eb2c fix(worktree): prevent removal of unpushed branches and uncommitted changes`
- **Purpose**: Worktree safety improvements
- **Status**: Check if fix is in main (may be merged via #42)

### feature/session-review-command
- **Commits**: 4 commits including /session-review and /full-loop commands
- **Purpose**: Session review and full-loop automation
- **Status**: Needs review, may have merge conflicts
