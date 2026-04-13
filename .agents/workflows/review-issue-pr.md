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

## 0. Pre-Review Discovery (MANDATORY)

Before reading the proposed fix, establish the current state of the codebase and the issue landscape. Skipping this step is how reviewers rubber-stamp fixes for problems that have already been solved, endorse caches that defeat recently-added invariants, or approve symptom-patches whose root cause lives elsewhere. The review verdict is only as good as this discovery step — if it's weak, the rest is decoration.

> **Shared discipline:** The same checks apply at implementation time, not just review time. `prompts/build.txt` "Pre-implementation discovery" mirrors this section for the implementer role — the discipline lives in both places so it cannot be bypassed by skipping review.

### 0.1 Duplicate and temporal-duplicate check

Two distinct checks, both required. The second is what's usually missed: an issue filed last week may have been silently solved by unrelated work that landed yesterday.

| Check | What to Run | What to Look For |
|-------|-------------|------------------|
| **Pre-existing duplicate** | `gh issue list --repo <slug> --search "<keywords>" --state all --limit 20` | Another open or closed issue reporting the same problem |
| **Superseded by in-flight PR** | `gh pr list --repo <slug> --state merged --search "<keywords>" --limit 10` then `gh pr list --state open --search "<keywords>"` | A recently-merged or in-review fix that already addresses this — the issue may be stale even if nobody marked it so |
| **Superseded by landed commit** | `git log --all --since="<issue date>" --oneline -- <affected files>` + `git log --all --since="<issue date>" --grep="<keywords>"` | A commit on any branch that addresses the same symptom or root cause |

If the issue is superseded, **stop and recommend closure** instead of reviewing the proposed fix. A fix for an already-solved problem is at best wasted effort and at worst a regression of the correct fix.

### 0.2 Affected-files discovery

Identify the files the issue or PR actually touches and read their **current** state — not the state described in the issue body, which may predate recent changes. A proposal that cites `file.sh:716` may now be wrong if unrelated work bumped the line numbers or refactored the surrounding function.

```bash
# Files mentioned in the issue body
gh issue view <num> --repo <slug> --json body --jq '.body' | rg -oE '[-.a-zA-Z0-9_/]+\.(sh|py|ts|js|md|json|yaml)'

# Their recent git activity (30 days is usually sufficient to catch drift)
git log --oneline --since="30 days ago" -- <files>

# Verify the issue's code quotes match current reality
sed -n 'START,ENDp' <file>
```

### 0.3 Framing critique

Verify the issue's cited symptoms actually match the codebase's behaviour. A reviewer who accepts the reporter's framing at face value can end up solving the wrong problem. Framing errors to catch:

- **"X keeps happening"** → grep the logs/state — is X actually happening, or is the reporter describing a pre-fix behaviour?
- **"Y is too expensive"** → measure the actual cost — is the expense real, or a hypothetical based on misreading the code path?
- **"Z is broken"** → check if Z is invoked at all — the cited path may be dead code, or the function may return early before reaching it.
- **"A locks/unlocks repeatedly"** → grep for the specific events — the observed "churn" may be a different mechanism entirely (e.g., the user may mean "cycles repeatedly" but frame it as "lock/unlock").

If the framing doesn't match reality, the review documents the mismatch before proposing changes. "The cited symptom doesn't reproduce, but here's what's actually happening" is more useful than reviewing a fix for a non-existent problem.

## Issue Review Checklist

### 1. Problem Validation

| Check | Question | How to Verify |
|-------|----------|---------------|
| **Reproducible** | Can we reproduce? | Follow steps, test locally |
| **Version confirmed** | Occurs on latest? | Check reporter's version vs current |
| **Not a pre-existing duplicate** | Already reported (open or closed)? | `gh issue list --search "<keywords>" --state all` |
| **Not superseded by recent work** | Solved or addressed since this was posted? | `git log --since="<issue date>"` + `gh pr list --state merged --search "<keywords>"` |
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

A fix that looks right in isolation can defeat invariants elsewhere. Every non-trivial review must answer these four questions explicitly — "I considered it and there are no concerns" is a valid answer, but the questions must be asked.

#### 6.1 Architectural intent

| Check | Question | Why It Matters |
|-------|----------|----------------|
| **Recent decisions** | Does this contradict an architectural change landed in the last 30 days? | A new cache can defeat a just-added invalidation; a new retry can defeat a just-added idempotency guard. Read the last 30 days of commits on affected files. |
| **Design rationale** | Why does the current behaviour exist? Is this "optimization" removing something load-bearing? | Comments and commit messages usually explain why — read them before proposing removal. |
| **Invariants** | What invariants does the current code maintain? Does the proposed change preserve them? | E.g., "content hash must invalidate on file change" — a proposed cache must honour this. |

#### 6.2 Safety gate interaction

aidevops has several safety gates. Every non-trivial change must be mapped against them:

| Gate | Trigger | Review Question |
|------|---------|-----------------|
| **Maintainer approval** (`needs-maintainer-review`, `ai-approved`, cryptographic) | Non-maintainer contributions | Does this bypass, weaken, or strengthen the approval chain? |
| **Sandbox boundary** (sandboxed agents, no-network execution) | Triage review, external content | Does this leak untrusted data into a trusted context, or vice versa? |
| **Dispatch dedup** (`dispatch-dedup-helper.sh`, origin labels, combined signal t1996) | Worker dispatch | Does this create or allow a race? |
| **Prompt injection scanner** | External-content processing | Does this accept untrusted content into a context that acts on instructions? |
| **Privacy guard** (pre-push hook, sanitiser) | Cross-repo work | Does this leak private repo names into public artifacts? |
| **Review bot gate** | PR merge | Does this lower the bar for merging external PRs? |
| **Origin labels** (`origin:interactive` / `origin:worker`) | Session provenance | Does this change behaviour based on provenance in a way that could be spoofed? |

If the change touches any gate, the review must call it out explicitly. "Does not touch any gate" is a valid answer — but the question must be asked.

#### 6.3 Symptom vs root cause

A fix that makes broken behaviour cheaper is not the same as a fix that makes the behaviour correct. These anti-patterns indicate the proposal is papering over a deeper bug:

| Signal | Indicates | Reviewer Action |
|--------|-----------|-----------------|
| Fix reduces cost without eliminating the failure | Symptom patch on broken behaviour | Flag: "is this a fix, or a cost reduction on broken behaviour?" — propose fixing the root cause instead, or in addition |
| Fix works around an error instead of preventing it | Defensive code masking a real bug | Flag: "what's the underlying bug? Should we fix that instead?" |
| Fix reduces a retry/backoff counter | Possibly papering over broken retries | Ask: "why are retries failing? Do they succeed after N attempts, or are they all failing identically?" |
| Fix adds a cache to something that re-runs every cycle | Possibly defeating an intentional re-check | Ask: "why does this re-run every cycle? What invariant does the re-check maintain?" |
| Fix raises a timeout or retry budget | Possibly masking a hang or an infinite loop | Ask: "what's timing out? Is the timeout the real problem, or is something stuck?" |

It is often correct to ship both: the cheaper symptom patch AND a separate issue for the root cause. The review should make the root cause visible even when endorsing the symptom fix.

#### 6.4 Ripple effects

For every non-trivial change, enumerate the downstream code paths that will behave differently after it lands. If the list is empty, you haven't looked hard enough. Common ripple targets:

- Tests that pin the current behaviour — will they start failing, and is that the right signal?
- Documentation that describes the current behaviour — will it become wrong?
- Metrics and dashboards that depend on the current signal — will they be misleading?
- Integration points where upstream/downstream code has assumptions — will they break?
- Rollback path — can we revert this cleanly if it goes wrong?
- Related features that share state or configuration with the changed code — will they be affected?

**Red flag**: if the reviewer can't enumerate any ripple effects, the review isn't ready. Invite the author to do it before merging.

## Review Output Format

Heading MUST contain `## Review:` or `## Issue/PR Review:` — pulse idempotency guard uses this marker to detect existing triage reviews.

```markdown
## Review: Approved / Needs Changes / Decline

### Pre-Review Context

| Check | Result |
|-------|--------|
| Pre-existing duplicates | [list issue numbers, or "None"] |
| Superseded by recent work | [list merged PRs or commits since the issue was posted, or "None"] |
| Framing matches reality | [Yes / Partial / No — with one-line evidence] |
| Current file state matches issue body references | [Yes / Drifted — cite specific drifted line numbers] |

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes/No | [details] |
| Not a pre-existing duplicate | Yes/No | [related issues, if any] |
| Not superseded by recent work | Yes/No | [recent PRs/commits checked] |
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

### Second-Order Effects

| Dimension | Finding |
|-----------|---------|
| Architectural intent | [Aligned / Contradicts / Unclear — cite recent commits if relevant] |
| Safety gates touched | [list gates from Section 6.2, or "None"] |
| Symptom vs root cause | [Root cause / Symptom patch — justify; if symptom, link or propose a root-cause issue] |
| Ripple effects | [enumerated list of downstream impacts; "None identified" requires explicit justification] |
| Rollback path | [how to revert; "trivial revert" is fine for small changes] |

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
>
> **Gap (t2017):** Section 0 (Pre-Review Discovery), Section 6 (Second-Order Effects), and the new output sections are currently only enforced in the interactive path. The sandboxed `triage-review.md` agent cannot run `gh pr list --state merged --search` or `git log --since` because it has no Bash/network. To bring the same discipline to pulse triage, the prefetch in `pulse-ancillary-dispatch.sh` must be extended to supply: (1) recent merged PRs matching the issue keywords, (2) recent commits on the affected files since the issue was posted, and (3) the current contents of those files at the cited line numbers. Tracked as a follow-up — see the companion issue created with this change.

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

### Issue Already Superseded by Recent Work

```markdown
Thanks for the report, @{reporter}. This is no longer reproducible after #{recent_pr} ({recent_pr_title}), which landed on {date} and addresses the same root cause. I verified by {verification}.

Closing as superseded. If you still see this on {latest_version}, please reopen with a fresh reproduction against the current code.
```

### Fix Addresses Symptom, Root Cause Lives Elsewhere

```markdown
The proposed fix works for the reported symptom, but the root cause is {root_cause_description}, which would still produce failures in {other_affected_paths} even after this lands.

Two options:
1. Fix the root cause in {correct_location} — reference pattern at {file:line}. The proposed change becomes unnecessary.
2. Ship this as a cost-reduction for the symptom AND file a separate issue for the root cause. Both endorsed, but the root-cause issue must exist before merging this one.

I'd prefer (1) unless {reason (1) is infeasible}. Happy to file the root-cause issue either way.
```

### Fix Defeats a Recent Architectural Decision

```markdown
The proposed change conflicts with #{recent_decision_pr} ({title}), which intentionally {what_it_added}. The fix proposed here would defeat that invariant because {mechanism}.

If the original decision needs revisiting, that's a separate discussion — we shouldn't regress it through a symptom-patch here. Options:
1. Find a fix that preserves the invariant from #{recent_decision_pr}.
2. Reopen the design question in a new issue with evidence that the original decision was wrong.

Requesting changes until one of those is answered.
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
