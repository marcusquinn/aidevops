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

## Pre-Review Discovery (MANDATORY)

Before evaluating the issue or PR, run these discovery checks to avoid temporal-duplicate blindness, framing acceptance, and symptom-vs-root-cause confusion.

### 0.1 Duplicate and Temporal-Duplicate Check

| Check | Command | What to Look For |
|-------|---------|------------------|
| **Pre-existing duplicate** | `gh issue list --search "keyword" --state all` | Same issue already reported (open or closed) |
| **Temporal duplicate** | `git log --since="<issue_date>" --oneline -- <affected_files>` | Recent commits that fix the same problem |
| **Recent merged PRs** | `gh pr list --state merged --search "keyword" --limit 20` | Merged fixes in the last 7 days matching issue keywords |

**Action**: If a temporal duplicate is found (recent commit or merged PR addressing the same root cause), redirect the conversation: "This was already fixed in PR #NNN (merged DATE). The fix will ship in the next release."

### 0.2 Affected-Files Discovery

Read the **current state** of files cited in the issue body, not the state described in the issue. Discrepancies signal:
- Issue is stale (problem already fixed)
- Issue describes a different code path than what exists now
- Framing is based on outdated assumptions

**How**: For each file mentioned in the issue, run:

```bash
git log --oneline -5 -- path/to/file
cat path/to/file | head -50  # or read the specific line range cited
```

**Red flag**: If the cited line numbers don't match the current file, the issue is stale or the framing is wrong.

### 0.3 Framing Critique

The issue body describes a **symptom and a proposed framing**. Verify the framing matches codebase reality:

- **Symptom**: What the user observed (e.g., "triage retries 3 times")
- **Framing**: The user's explanation (e.g., "lock/unlock for gated issues")
- **Reality check**: Does the code path described in the framing actually exist? Is the symptom caused by that path?

**How**: Search the codebase for the framing's key terms:

```bash
rg "lock|unlock" --type sh --type py  # if framing mentions lock/unlock
rg "TRIAGE_MAX_RETRIES" .agents/scripts/  # if framing mentions retries
```

**Red flag**: If the framing's key terms don't appear in the code, or appear in a different context, the issue is misframed. The real problem lives elsewhere.

---

## Issue Review Checklist

### 1. Problem Validation

| Check | Question | How to Verify |
|-------|----------|---------------|
| **Reproducible** | Can we reproduce? | Follow steps, test locally |
| **Version confirmed** | Occurs on latest? | Check reporter's version vs current |
| **Not a pre-existing duplicate** | Already reported? | Search closed/open issues |
| **Not superseded by recent work** | Fixed in last 7 days? | `git log --since`, `gh pr list --state merged` (see 0.1) |
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

### 6. Second-Order Effects and Safety Gates

After validating the problem and evaluating the solution, check for unintended consequences and architectural conflicts.

#### 6.1 Architectural Intent

Does this change contradict a decision landed in the last 30 days?

**How**: Search recent commits for architectural decisions:

```bash
git log --since="30 days ago" --oneline --grep="architecture\|design\|decision" -- .agents/
git log --since="30 days ago" --oneline -- .agents/aidevops/architecture.md
```

**Red flag**: If the proposed fix contradicts a recent architectural decision (e.g., "we just added a dedup gate, and this PR defeats it"), the fix is solving the wrong problem or the recent decision needs revisiting.

#### 6.2 Safety Gate Interaction

Map the change against these seven enumerated gates:

| Gate | What It Protects | Check |
|------|------------------|-------|
| **Maintainer approval** | Prevents unauthorized changes | Does this bypass `sudo aidevops approve`? |
| **Sandbox isolation** | Prevents headless agents from editing main | Does this allow headless writes to main? |
| **Dedup guard** | Prevents duplicate dispatch | Does this defeat `dispatch-dedup-helper.sh`? |
| **Prompt injection** | Prevents instruction override | Does this allow external content to modify behavior? |
| **Privacy guard** | Prevents private repo leaks | Does this expose private slugs in public repos? |
| **Review bot gate** | Prevents merge without review | Does this skip `review-bot-gate-helper.sh check`? |
| **Origin labels** | Tracks work provenance | Does this break `origin:interactive` / `origin:worker` tracking? |

**Red flag**: If the change defeats or bypasses any gate, it's a security or audit trail issue. Reject unless the gate itself is being intentionally updated.

#### 6.3 Symptom vs Root Cause

Five anti-patterns signal the proposal is papering over a deeper bug:

1. **Reducing retry limits** — "Set `MAX_RETRIES=1`" when retries are failing identically every time (symptom: retries are broken; root cause: the thing being retried is 100% broken)
2. **Adding cache/memoization** — "Cache the result" when the result is computed incorrectly (symptom: slow; root cause: wrong algorithm)
3. **Increasing timeouts** — "Raise the timeout" when the operation hangs (symptom: slow; root cause: deadlock or infinite loop)
4. **Silencing errors** — "Suppress the warning" when the warning is correct (symptom: noisy logs; root cause: the underlying issue is real)
5. **Changing thresholds** — "Raise the threshold" when the threshold is being exceeded legitimately (symptom: too many alerts; root cause: the system is overloaded)

**How**: For each proposal, ask: "If we do this, does the underlying problem still exist?" If yes, it's a symptom fix.

**Red flag**: If the proposal is one of these five patterns, ask the reporter to investigate the root cause first.

#### 6.4 Ripple Effects

Enumerate downstream code paths that depend on the changed behavior. An empty list is a red flag.

**How**: For each changed function/config/gate, search for callers:

```bash
rg "function_name|config_key" --type sh --type py
git log --all --oneline --grep="function_name"
```

**Red flag**: If no downstream code uses the changed behavior, it's dead code or the change is incomplete. If many downstream paths use it, the change is high-risk — ensure all callers are tested.

---

## Review Output Format

Heading MUST contain `## Review:` or `## Issue/PR Review:` — pulse idempotency guard uses this marker to detect existing triage reviews.

```markdown
## Review: Approved / Needs Changes / Decline

### Pre-Review Context

- **Temporal duplicates**: [any recent commits/PRs fixing the same issue?]
- **Affected files**: [current state of cited files; any discrepancies with issue description?]
- **Framing critique**: [does the issue's framing match codebase reality?]

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes/No | [details] |
| Not a pre-existing duplicate | Yes/No | [related issues] |
| Not superseded by recent work | Yes/No | [recent commits/PRs?] |
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

### Second-Order Effects

- **Architectural intent**: [any recent decisions this contradicts?]
- **Safety gates**: [does this defeat any gates? (maintainer approval, sandbox, dedup, prompt injection, privacy, review bot, origin labels)]
- **Symptom vs root cause**: [is this papering over a deeper bug?]
- **Ripple effects**: [downstream code paths affected; empty list = red flag]

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

> **Gap (t2017):** The sandboxed `triage-review.md` agent cannot run the discovery checks in Section 0 (temporal-duplicate, affected-files, framing critique) because it has no Bash/network tools. Bringing the same discipline to pulse triage requires extending the prefetch in `pulse-ancillary-dispatch.sh` to pass discovery data inline: (1) recent merged PRs matching issue keywords, (2) recent commits on affected files, (3) current file contents at cited line numbers. Tracked as a separate follow-up task.

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

### Issue Already Superseded by Recent Work

```markdown
This issue was already addressed in PR #NNN, which merged on DATE. The fix will ship in the next release.

- **Your issue**: [symptom]
- **Recent fix**: [PR #NNN] — [what it fixed]

No further action needed. Closing as superseded.
```

### Fix Addresses Symptom, Root Cause Lives Elsewhere

```markdown
The proposed fix reduces the cost of the symptom, but the root cause should be addressed instead:

- **Symptom**: [what the user observed]
- **Proposed fix**: [what the PR does] — reduces cost by X%
- **Root cause**: [underlying issue]
- **Better approach**: [fix the root cause instead]

Example: If retries are failing identically every time, the issue is not "retries are expensive" (reduce `MAX_RETRIES`), but "the thing being retried is broken" (fix the retry target).

Would you be open to investigating the root cause? Happy to discuss.
```

### Fix Defeats a Recent Architectural Decision

```markdown
This fix contradicts a decision we landed recently:

- **Your fix**: [what it changes]
- **Recent decision**: [PR #NNN, DATE] — [why we made it]
- **Conflict**: [how they contradict]

Before proceeding, let's discuss whether the recent decision needs revisiting, or if there's a different approach that respects both.
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
