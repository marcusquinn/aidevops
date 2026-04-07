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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Review External Issues and PRs

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Triage and review issues/PRs — interactive or pulse-automated
- **Focus**: Validate the problem exists, evaluate if the solution is optimal
- **When**: Before approving/merging contributions, or automatically by the pulse for `needs-maintainer-review` items

**Core Questions**:
1. **Is the issue real?** — Reproducible? Bug or expected behavior?
2. **Is this the best solution?** — Simpler alternatives? Fits architecture?
3. **Is the scope appropriate?** — PR does exactly what's needed, no more?

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

- Actual root cause? (Surface symptoms may hide deeper issues)
- Symptom of a larger problem? (Fixing symptoms creates tech debt)
- Why wasn't this caught earlier? (Missing tests or docs?)
- Related issues? (Batch fixes may be more efficient)

## PR Review Checklist

### 3. Solution Evaluation

| Criterion | Questions to Ask |
|-----------|------------------|
| **Simplicity** | Simpler way? One-liner? Existing utility or stdlib? |
| **Correctness** | Fixes root cause, not just symptom? |
| **Completeness** | Edge cases and error conditions handled? |
| **Consistency** | Follows existing codebase patterns? Right abstraction level? |
| **Performance** | Introduces regressions? |
| **Maintainability** | Easy to maintain, understand, debug? |

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

Heading MUST contain `## Review:` or `## Issue/PR Review:` — pulse idempotency guard uses this marker to detect existing triage reviews.

```markdown
## Review: Approved / Needs Changes / Decline

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes/No | [details] |
| Not duplicate | Yes/No | [related issues] |
| Actual bug | Yes/No | [or expected behavior?] |
| In scope | Yes/No | [project goal alignment] |

**Root Cause**: [Brief description]

### Solution Evaluation (if PR)

| Criterion | Assessment | Notes |
|-----------|------------|-------|
| Simplicity | Good/Needs Work | [simpler alternatives?] |
| Correctness | Good/Needs Work | [fixes root cause?] |
| Completeness | Good/Needs Work | [edge cases?] |
| Consistency | Good/Needs Work | [follows patterns?] |

**Alternatives**: [Recommended approach] - [why]

### Scope & Recommendation

- Scope creep: Low/Medium/High
- Complexity: Low (`tier:simple`) / Medium (`tier:standard`) / High (`tier:reasoning`)
- **Decision**: APPROVE / REQUEST CHANGES / DECLINE
- **Labels**: [e.g., `tier:simple`, `bug`, `status:available`]
- **Implementation guidance**: [key steps, test cases to add]

### Dispatchability Assessment

| Check | Status | Notes |
|-------|--------|-------|
| Brief exists | Yes/No | `todo/tasks/{id}-brief.md` |
| Brief has code blocks | Yes/No | Required for `tier:simple` |
| TODO entry with ref | Yes/No | `ref:GH#NNN` in TODO.md |
| Task ID claimed | Yes/No | via `claim-task-id.sh` |

**Tier prerequisite met**: Yes/No — [does brief quality match the recommended tier? See AGENTS.md "Briefs, Tiers, and Dispatchability"]
**What's needed to dispatch**: [list missing prerequisites, or "Ready for dispatch"]
```

**Why this section exists**: Tier recommendations without brief verification led to issues being labelled `tier:simple` when no brief with code blocks existed — making them undispatchable at that tier. This section forces the reviewer to check prerequisites before recommending a tier, whether invoked via `/review-issue-pr` or encountered mid-session. See AGENTS.md "Briefs, Tiers, and Dispatchability" for the full prerequisite chain.

## Closing the Loop with the Reporter

After a verdict is reached, the reporter must always be informed — regardless of outcome. This step is mandatory, not optional.

| Outcome | Action |
|---------|--------|
| APPROVE → internal task created | Comment on source issue: thank reporter, link to internal task/PR, set expectation on timeline |
| APPROVE → PR merged same session | Comment on source issue: thank reporter, link to merged PR, close issue |
| REQUEST CHANGES | Comment explaining what needs to change before the fix can proceed |
| DECLINE | Comment explaining why (out of scope, by design, duplicate) and close issue |

**Template — issue converted to internal task:**

```markdown
Thanks for the report, @{reporter}.

Accepted. Tracked internally as #{internal_issue} and implemented in PR #{pr_number} (now merged). This will be included in the next `aidevops update`.

Closing this as resolved.
```

**Template — issue approved but pending implementation:**

```markdown
Thanks for the report, @{reporter}.

Accepted and queued for implementation as #{internal_issue}. We'll link back here when the fix ships.
```

**When to skip:** Pulse-automated triage only (headless mode without a human session). The pulse posts its own review comment; the maintainer closes the loop after approving.

## Headless / Pulse-Driven Mode

> **Note (t1894):** Pulse-dispatched triage reviews now use the sandboxed `triage-review.md` agent which has NO Bash/network access. This file (`review-issue-pr.md`) is only used for interactive `/review-issue-pr` sessions where the user is present. The sandboxed agent receives all GitHub data pre-fetched by deterministic code.

When invoked by pulse (via `/review-issue-pr <number>`):

1. Fetch issue/PR: `gh issue view` or `gh pr view`
2. Read codebase files referenced in the issue body
3. Run full review checklist (validation, root cause, solution, scope)
4. Post review comment: `gh issue comment` or `gh pr comment`
5. Do NOT modify labels — pulse handles label transitions
6. Exit cleanly — no worktree, no PR, no commit

The review comment is the only output. Pulse detects it next cycle; maintainer responds with "approved", "declined", or direction. If dispatch prompt includes prior maintainer comments, address those concerns specifically.

## Common Scenarios

### Issue is Not a Bug

```markdown
After investigation, this is expected behavior:
- [Why this is by design]
- [Link to docs]

To request different behavior, open a feature request. Closing as "not a bug" — reopen with additional context if needed.
```

### PR Fixes Symptom, Not Cause

```markdown
The fix works for the reported case, but the root cause should be addressed:
- **Current approach**: [what the PR does]
- **Root cause**: [underlying issue]
- **Suggested approach**: [better solution]

Would you be open to updating? Happy to discuss.
```

### PR Has Scope Creep

```markdown
Core fix looks good, but some changes should be separate PRs:
- **In scope** (keep): [change 1], [change 2]
- **Out of scope** (separate PR): [change 3] — [reason]

Could you split this into focused PRs?
```

### Better Alternative Exists

```markdown
There's a simpler approach:
- **Your approach**: [summary]
- **Alternative**: [simpler solution] — preferable because [reason]

Would you be open to updating? Or I can make the change.
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
