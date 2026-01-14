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

1. **Is the issue real?** - Can we reproduce? Is it actually a bug or expected behavior?
2. **Is this the best solution?** - Are there simpler alternatives? Does it fit architecture?
3. **Is the scope appropriate?** - Does the PR do exactly what's needed, no more, no less?

**Usage** (paste URL or reference this workflow):

```bash
# Paste issue/PR URL and ask AI to review using this workflow
# Example: "Review this issue using workflows/review-issue-pr.md"
# https://github.com/owner/repo/issues/123

# Or use gh CLI directly
gh issue view 123 --json title,body,labels,author
gh pr view 456 --json title,body,files,additions,deletions
```

<!-- AI-CONTEXT-END -->

## Purpose

External contributions require different review criteria than internal work. This workflow ensures:

1. **Problem validation** - The issue describes a real, reproducible problem
2. **Solution evaluation** - The proposed fix is the best approach, not just a working one
3. **Scope control** - Changes are minimal and focused on the stated problem
4. **Architecture alignment** - The solution fits existing patterns and doesn't introduce tech debt

## Workflow Position

```text
External Issue/PR Submitted
         |
         v
+-------------------+
| review-issue-pr   |  <-- This workflow
|                   |
| 1. Validate issue |
| 2. Evaluate fix   |
| 3. Check scope    |
| 4. Architecture   |
+-------------------+
         |
    +----+----+
    |         |
    v         v
 Approve   Request
 & Merge   Changes
```

## Issue Review Checklist

### 1. Problem Validation

Before accepting any issue, verify:

| Check | Question | How to Verify |
|-------|----------|---------------|
| **Reproducible** | Can we reproduce the issue? | Follow steps in issue, test locally |
| **Version confirmed** | Does it occur on latest version? | Check reporter's version vs current |
| **Not duplicate** | Is this already reported? | Search closed/open issues |
| **Actual bug** | Is this a bug or expected behavior? | Check documentation, design decisions |
| **In scope** | Is this within project scope? | Check project goals, roadmap |

**Validation Commands**:

```bash
# Check if issue exists
gh issue view 123 --json title,body,labels,state

# Search for duplicates
gh issue list --search "keyword" --state all

# Check reporter's environment
gh issue view 123 --json body | jq -r '.body' | grep -i "version\|environment"
```

### 2. Root Cause Analysis

Before evaluating solutions:

| Question | Why It Matters |
|----------|----------------|
| What's the actual root cause? | Surface symptoms may hide deeper issues |
| Is this a symptom of a larger problem? | Fixing symptoms creates tech debt |
| Why wasn't this caught earlier? | May indicate missing tests or docs |
| Are there related issues? | Batch fixes may be more efficient |

**Analysis Commands**:

```bash
# Find related code (use multiple --include flags)
grep -r "relevant_function" --include='*.js' --include='*.ts' --include='*.py' --include='*.sh'

# Check git history for the area
git log --oneline -20 -- path/to/affected/file

# Find related issues
gh issue list --search "related keyword" --json number,title
```

## PR Review Checklist

### 3. Solution Evaluation

The critical question: **Is this the best solution?**

| Criterion | Questions to Ask |
|-----------|------------------|
| **Simplicity** | Is there a simpler way? Could this be a one-liner? |
| **Correctness** | Does it actually fix the root cause, not just the symptom? |
| **Completeness** | Does it handle edge cases? Error conditions? |
| **Consistency** | Does it follow existing patterns in the codebase? |
| **Performance** | Does it introduce performance regressions? |
| **Maintainability** | Will this be easy to maintain? Understand? Debug? |

**Alternative Solution Checklist**:

```markdown
Before approving, consider:
- [ ] Could this be solved with existing utilities/functions?
- [ ] Is there a standard library solution?
- [ ] Would a different approach be more maintainable?
- [ ] Does the codebase already have a pattern for this?
- [ ] Is the fix at the right abstraction level?
```

### 4. Scope Assessment

PRs should be minimal and focused:

| Red Flag | What It Indicates |
|----------|-------------------|
| Unrelated file changes | Scope creep, should be separate PR |
| Refactoring mixed with fixes | Hard to review, may hide issues |
| "While I was here" changes | Increases risk, harder to revert |
| Missing from PR description | Undocumented changes are suspicious |

**Scope Check Commands**:

```bash
# List all changed files
gh pr view 456 --json files | jq -r '.files[].path'

# Compare PR description to actual changes
gh pr view 456 --json body,files

# Check diff size
gh pr diff 456 --stat
```

### 5. Architecture Alignment

Does the solution fit the project?

| Check | Question |
|-------|----------|
| **Patterns** | Does it follow existing code patterns? |
| **Dependencies** | Does it add new dependencies? Are they justified? |
| **API surface** | Does it change public APIs? Is that intentional? |
| **Breaking changes** | Does it break backward compatibility? |
| **Test coverage** | Are there adequate tests? Do they test the right things? |

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

**Root Cause**: [Brief description of actual root cause]

### Solution Evaluation

| Criterion | Assessment | Notes |
|-----------|------------|-------|
| Simplicity | Good/Needs Work | [simpler alternatives?] |
| Correctness | Good/Needs Work | [fixes root cause?] |
| Completeness | Good/Needs Work | [edge cases covered?] |
| Consistency | Good/Needs Work | [follows patterns?] |

**Alternative Approaches Considered**:
1. [Alternative 1] - [why not chosen]
2. [Alternative 2] - [why not chosen]

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
2. [Change 2]

**Suggestions** (optional improvements):
1. [Suggestion 1]
2. [Suggestion 2]
```

## Common Scenarios

### Scenario: Issue is Not a Bug

```markdown
**Response Template**:

Thanks for reporting this! After investigation, this appears to be expected behavior:

- [Explanation of why this is by design]
- [Link to relevant documentation]

If you believe this should work differently, please open a feature request 
describing your use case and the expected behavior.

Closing as "not a bug" - feel free to reopen with additional context if I've 
misunderstood the issue.
```

### Scenario: PR Fixes Symptom, Not Cause

```markdown
**Response Template**:

Thanks for the PR! The fix works for the reported case, but I think we should 
address the root cause instead:

**Current approach**: [what the PR does]
**Root cause**: [actual underlying issue]
**Suggested approach**: [better solution]

Would you be open to updating the PR to address the root cause? Happy to 
discuss the approach if you'd like more details.
```

### Scenario: PR Has Scope Creep

```markdown
**Response Template**:

Thanks for the contribution! The core fix looks good, but I noticed some 
additional changes that should be in separate PRs:

**In scope** (keep in this PR):
- [change 1]
- [change 2]

**Out of scope** (please move to separate PR):
- [change 3] - [reason]
- [change 4] - [reason]

Could you split this into focused PRs? It makes review easier and keeps our 
git history clean. Happy to review the separate PRs once they're ready!
```

### Scenario: Better Alternative Exists

```markdown
**Response Template**:

Thanks for tackling this issue! I appreciate the effort, but I think there's 
a simpler approach we should consider:

**Your approach**: [summary]
**Alternative**: [simpler solution]

The alternative is preferable because:
1. [reason 1]
2. [reason 2]

Would you be open to updating the PR with this approach? Or if you prefer, 
I can make the change - just let me know!
```

## CLI Commands

```bash
# Fetch issue details
gh issue view 123 --json title,body,labels,author,createdAt,comments

# Fetch PR details with diff
gh pr view 456 --json title,body,files,additions,deletions,author
gh pr diff 456

# Check CI status on PR
gh pr checks 456

# Add review comment
gh pr review 456 --comment --body "Comment text"

# Request changes
gh pr review 456 --request-changes --body "Please address..."

# Approve PR
gh pr review 456 --approve --body "LGTM!"

# Close issue with comment
gh issue close 123 --comment "Closing because..."
```

## Labels for Triage

Recommended labels for issue triage:

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
| `workflows/pr.md` | After approving external PR, run full quality checks |
| `tools/code-review/code-standards.md` | Reference for evaluating code quality |
| `/linters-local` | Run before final approval |
| `tools/git/github-cli.md` | GitHub CLI reference |
| `workflows/pr.md` (Fork Workflow) | When contributor uses fork workflow |
