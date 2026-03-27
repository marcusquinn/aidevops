---
description: Review external issues and PRs - validate problems and evaluate proposed solutions
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

# Review External Issues and PRs

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Triage and review issues/PRs submitted by external contributors
- **Focus**: Validate the problem exists, evaluate if the solution is optimal
- **When**: Before approving/merging external contributions

**Core Questions**:

1. **Is the issue real?** — Can we reproduce? Bug or expected behavior?
2. **Is this the best solution?** — Simpler alternatives? Fits architecture?
3. **Is the scope appropriate?** — Does the PR do exactly what's needed, no more?

```bash
gh issue view 123 --json title,body,labels,author
gh pr view 456 --json title,body,files,additions,deletions
```

<!-- AI-CONTEXT-END -->

## Issue Review Checklist

### 1. Problem Validation

| Check | Question | How to Verify |
|-------|----------|---------------|
| **Reproducible** | Can we reproduce? | Follow steps, test locally |
| **Version confirmed** | Occurs on latest? | Check reporter's version vs current |
| **Not duplicate** | Already reported? | Search closed/open issues |
| **Actual bug** | Bug or expected behavior? | Check docs, design decisions |
| **In scope** | Within project scope? | Check project goals, roadmap |

```bash
gh issue view 123 --json title,body,labels,state
gh issue list --search "keyword" --state all
gh issue view 123 --json body | jq -r '.body' | grep -i "version\|environment"
```

### 2. Root Cause Analysis

| Question | Why It Matters |
|----------|----------------|
| What's the actual root cause? | Surface symptoms may hide deeper issues |
| Is this a symptom of a larger problem? | Fixing symptoms creates tech debt |
| Why wasn't this caught earlier? | May indicate missing tests or docs |
| Are there related issues? | Batch fixes may be more efficient |

```bash
rg "relevant_function" --type js --type ts --type py --type sh
git log --oneline -20 -- path/to/affected/file
gh issue list --search "related keyword" --json number,title
```

## PR Review Checklist

### 3. Solution Evaluation

| Criterion | Questions to Ask |
|-----------|------------------|
| **Simplicity** | Is there a simpler way? Could this be a one-liner? |
| **Correctness** | Fixes root cause, not just symptom? |
| **Completeness** | Handles edge cases and error conditions? |
| **Consistency** | Follows existing codebase patterns? |
| **Performance** | Introduces regressions? |
| **Maintainability** | Easy to maintain, understand, debug? |

Before approving, consider:
- [ ] Could this use existing utilities/functions?
- [ ] Is there a standard library solution?
- [ ] Would a different approach be more maintainable?
- [ ] Does the codebase already have a pattern for this?
- [ ] Is the fix at the right abstraction level?

### 4. Scope Assessment

| Red Flag | What It Indicates |
|----------|-------------------|
| Unrelated file changes | Scope creep — should be separate PR |
| Refactoring mixed with fixes | Hard to review, may hide issues |
| "While I was here" changes | Increases risk, harder to revert |
| Missing from PR description | Undocumented changes are suspicious |

```bash
gh pr view 456 --json files | jq -r '.files[].path'
gh pr view 456 --json body,files
gh pr diff 456 --stat
```

### 5. Architecture Alignment

| Check | Question |
|-------|----------|
| **Patterns** | Follows existing code patterns? |
| **Dependencies** | New deps added? Are they justified? |
| **API surface** | Changes public APIs intentionally? |
| **Breaking changes** | Breaks backward compatibility? |
| **Test coverage** | Adequate tests for the right things? |

## Review Output Format

```markdown
## Issue/PR Review: #123 - [Title]

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes/No | [details] |
| Not duplicate | Yes/No | [related issues if any] |
| Actual bug | Yes/No | [or expected behavior?] |
| In scope | Yes/No | [alignment with project goals] |

**Root Cause**: [Brief description]

### Solution Evaluation

| Criterion | Assessment | Notes |
|-----------|------------|-------|
| Simplicity | Good/Needs Work | [simpler alternatives?] |
| Correctness | Good/Needs Work | [fixes root cause?] |
| Completeness | Good/Needs Work | [edge cases covered?] |
| Consistency | Good/Needs Work | [follows patterns?] |

**Alternative Approaches Considered**:
1. [Alternative 1] - [why not chosen]

### Scope Assessment

- [ ] All changes documented in PR description
- [ ] No unrelated changes
- [ ] Minimal diff for the fix
- [ ] No "while I was here" additions

**Undocumented Changes**: [list any, or "None"]

### Recommendation

**Decision**: APPROVE / REQUEST CHANGES / CLOSE

**Required Changes** (if any):
1. [Change 1]

**Suggestions** (optional):
1. [Suggestion 1]
```

## Common Scenarios

### Issue is Not a Bug

```markdown
Thanks for reporting this! After investigation, this appears to be expected behavior:
- [Explanation of why this is by design]
- [Link to relevant documentation]

If you believe this should work differently, please open a feature request.
Closing as "not a bug" — feel free to reopen with additional context.
```

### PR Fixes Symptom, Not Cause

```markdown
Thanks for the PR! The fix works for the reported case, but we should address the root cause:
- **Current approach**: [what the PR does]
- **Root cause**: [actual underlying issue]
- **Suggested approach**: [better solution]

Would you be open to updating the PR? Happy to discuss.
```

### PR Has Scope Creep

```markdown
The core fix looks good, but some changes should be in separate PRs:
- **In scope** (keep): [change 1], [change 2]
- **Out of scope** (separate PR): [change 3] — [reason]

Could you split this into focused PRs?
```

### Better Alternative Exists

```markdown
Thanks for tackling this! There's a simpler approach to consider:
- **Your approach**: [summary]
- **Alternative**: [simpler solution] — preferable because [reason]

Would you be open to updating the PR? Or I can make the change — just let me know.
```

## CLI Commands

```bash
gh issue view 123 --json title,body,labels,author,createdAt,comments
gh pr view 456 --json title,body,files,additions,deletions,author
gh pr diff 456
gh pr checks 456
gh pr review 456 --comment --body "Comment text"
gh pr review 456 --request-changes --body "Please address..."
gh pr review 456 --approve --body "LGTM!"
gh issue close 123 --comment "Closing because..."
```

## Labels for Triage

| Label | Meaning |
|-------|---------|
| `needs-reproduction` | Cannot reproduce, need more info |
| `needs-investigation` | Valid issue, needs root cause analysis |
| `good-first-issue` | Simple fix, good for new contributors |
| `help-wanted` | We'd welcome a PR for this |
| `wontfix` | By design or out of scope |
| `duplicate` | Already reported |
| `invalid` | Not a real issue |

## Related Workflows

| Workflow | When to Use |
|----------|-------------|
| `workflows/pr.md` | After approving, run full quality checks |
| `tools/code-review/code-standards.md` | Evaluating code quality |
| `/linters-local` | Run before final approval |
| `tools/git/github-cli.md` | GitHub CLI reference |
