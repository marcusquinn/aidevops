# Branch Inventory

Generated: 2026-01-11
Updated: 2026-01-11 (after processing branches 1-4)

This document tracks all unmerged branches with work-in-progress. All branches have been pushed to remote for preservation.

## Summary

| Category | Count | Status |
|----------|-------|--------|
| Unmerged branches | 9 | Remaining after cleanup |
| Merged/Closed | 4 | Processed this session |
| Active worktrees | 1 | `feature/memory-auto-capture` |

## Processed Branches (This Session)

| Branch | PR | Result |
|--------|-----|--------|
| `bugfix/sonarcloud-default-cases` | #44 | Merged |
| `chore/add-missing-opencode-commands` | #45 | Closed (changes in main via #46) |
| `chore/agent-review-improvements` | #46 | Merged |
| `chore/agents-md-progressive-disclosure` | #47 | Closed (changes in main) |

## Remaining Branches

### Ready to Review (Single Commit, Complete)

| Branch | Commit | Description | Action |
|--------|--------|-------------|--------|
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
| `~/Git/aidevops-feature-memory-auto-capture` | `feature/memory-auto-capture` | Clean |

## Next Steps

1. **Review remaining 4 chore branches** - Create PRs and merge
2. **Evaluate 5 feature branches** - Check if superseded or still needed
3. **Clean up worktree** - After `feature/memory-auto-capture` is resolved

## Cleanup Commands

```bash
# Delete remote branches that were merged/closed
git push origin --delete bugfix/sonarcloud-default-cases
git push origin --delete chore/add-missing-opencode-commands
git push origin --delete chore/agent-review-improvements
git push origin --delete chore/agents-md-progressive-disclosure

# Recreate any branch from remote when needed
git checkout -b <branch> origin/<branch>
```
