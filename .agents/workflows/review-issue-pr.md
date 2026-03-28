---
description: Review external issues and PRs - validate problems and evaluate proposed solutions. Used interactively and by the pulse supervisor for automated triage of needs-maintainer-review items.
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

- **Purpose**: Triage and review issues/PRs — interactive or pulse-automated
- **Focus**: Validate the problem exists, evaluate if the solution is optimal
- **When**: Before approving/merging contributions, or automatically by the pulse for `needs-maintainer-review` items
- **Modes**: Interactive (user invokes `/review-issue-pr`) or headless (pulse dispatches for triage)

**Core Questions**:
1. **Is the issue real?** — Can we reproduce? Bug or expected behavior?
2. **Is this the best solution?** — Simpler alternatives? Fits architecture?
3. **Is the scope appropriate?** — Does the PR do exactly what's needed, no more?

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

### 2. Root Cause Analysis

- What's the actual root cause? (Surface symptoms may hide deeper issues)
- Is this a symptom of a larger problem? (Fixing symptoms creates tech debt)
- Why wasn't this caught earlier? (May indicate missing tests or docs)
- Are there related issues? (Batch fixes may be more efficient)

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

### 5. Architecture Alignment

| Check | Question |
|-------|----------|
| **Patterns** | Follows existing code patterns? |
| **Dependencies** | New deps added? Are they justified? |
| **API surface** | Changes public APIs intentionally? |
| **Breaking changes** | Breaks backward compatibility? |
| **Test coverage** | Adequate tests for the right things? |

## Review Output Format

The review comment MUST contain `## Review:` or `## Issue/PR Review:` in the heading — this is the marker the pulse uses to detect whether a triage review has already been posted (idempotency guard).

```markdown
## Review: Approved / Needs Changes / Decline

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes/No | [details] |
| Not duplicate | Yes/No | [related issues if any] |
| Actual bug | Yes/No | [or expected behavior?] |
| In scope | Yes/No | [alignment with project goals] |

**Root Cause**: [Brief description]

### Solution Evaluation (if PR or proposed fix)

| Criterion | Assessment | Notes |
|-----------|------------|-------|
| Simplicity | Good/Needs Work | [simpler alternatives?] |
| Correctness | Good/Needs Work | [fixes root cause?] |
| Completeness | Good/Needs Work | [edge cases covered?] |
| Consistency | Good/Needs Work | [follows patterns?] |

**Alternative Approaches (Recommended)**:
1. [Recommended approach] - [why]

### Scope Assessment

- Scope creep risk: Low/Medium/High
- Complexity: Low (tier:simple) / Medium (default sonnet) / High (tier:thinking)

### Recommendation

**Decision**: APPROVE / REQUEST CHANGES / DECLINE

**Suggested labels**: [e.g., `tier:simple`, `bug`, `status:available`]

**Implementation guidance** (if approving):
1. [Key implementation step]
2. [Test case to add]
```

## Headless / Pulse-Driven Mode

When invoked by the pulse supervisor (via `/review-issue-pr <number>`):

1. Fetch the issue/PR using `gh issue view` or `gh pr view`
2. Read relevant codebase files referenced in the issue body
3. Perform the full review checklist (problem validation, root cause, solution evaluation, scope)
4. Post the review as a comment using `gh issue comment` or `gh pr comment`
5. Do NOT modify labels — the pulse handles label transitions based on maintainer response
6. Exit cleanly — no worktree, no PR, no commit

**The review comment is the only output.** The pulse detects it on the next cycle. The maintainer reads the review and responds with "approved", "declined", or further direction.

**Incorporating maintainer feedback:** If the dispatch prompt includes prior maintainer comments, incorporate that context and address the maintainer's specific concerns in the analysis.

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
gh issue list --search "keyword" --state all
gh pr view 456 --json title,body,files,additions,deletions,author
gh pr diff 456 --stat
gh pr checks 456
gh pr review 456 --comment --body "Comment text"
gh pr review 456 --request-changes --body "Please address..."
gh pr review 456 --approve --body "LGTM!"
gh issue close 123 --comment "Closing because..."
rg "relevant_function" --type js --type ts --type py --type sh
git log --oneline -20 -- path/to/affected/file
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
