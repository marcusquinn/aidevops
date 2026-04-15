<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Brief Composition Templates

Reference templates for GitHub-written content. Use `workflows/brief.md` for the shared formatting rules; this file only defines the outer shells.

## Issue Body Template

Wrap the appropriate tier content in this structure for `gh issue create`:

```markdown
## Description

{1-2 sentence summary of what needs to change and why}

## Implementation

{Tier-appropriate content from tier-simple.md, tier-standard.md, or tier-thinking.md}

## Acceptance Criteria

- [ ] {criterion with verify block if possible}
- [ ] Lint clean
- [ ] No unrelated changes

## Done When

{Concrete, machine-verifiable completion signal — the worker does not stop until these are true}

- `{lint/test command}` exits 0
- PR exists with `Closes #{issue_number}` in body
- MERGE_SUMMARY comment posted on PR
- Issue closed with closing comment linking PR
```

Always include a tier label: `tier:simple`, `tier:standard`, or `tier:thinking`.

**Why "Done When" matters:** Workers without a concrete completion signal fail in two ways: (1) stop after exploration without implementing (#17642, #17643), or (2) stop after PR creation without completing closure steps (merge, closing comments). The checklist drives toward verified completion instead of an open-ended goal.

## Comment Templates

### Dispatch comment (pulse → worker)

For pulse-dispatched workers. Include enough context to avoid re-reading the full issue:

```markdown
## Dispatching: {issue_title}

**Tier:** `tier:{tier}` | **Model:** {resolved_model} | **Agent:** {agent_name}
**Issue:** #{issue_number} | **Repo:** {repo_slug}

### Context for worker
{1-2 sentence summary of what the issue asks for}

### Key files
- `{primary_file:line_range}` — {what to change}
{additional files if multi-file}

_Dispatched by pulse at {timestamp}_
```

### Kill/timeout comment (watchdog → issue)

For killed workers. Explain what happened and guide the next attempt:

```markdown
## Worker killed: {reason}

**Duration:** {time} | **Tokens:** {tokens} | **Previous tier:** `tier:{tier}`

### What the worker spent time on
- {What files it read}
- {What approaches it tried, if visible from logs}

### Why it likely failed
- {Assessment: brief too vague? File changed? Multi-file coordination?}

### Guidance for next attempt
- {Specific advice: "Read the escalation report above" / "The brief lacks file paths — enrich before re-dispatch"}

_Killed by watchdog at {timestamp}_
```

### Escalation comment (cascade dispatch)

See `templates/escalation-report-template.md`. Include:
1. What was attempted (files read, code tried)
2. Structured reason code (see the template taxonomy)
3. Discoveries reusable by the next tier
4. Brief gaps (what was missing or unclear)

## PR Description Template

For all worker-created PRs. Serves review bots and human reviewers.

```markdown
## Summary

{1-3 bullet points: what changed and why}

## Changes

- `{file_path}` — {what changed in this file}

## Verification

- {Test output, lint results, or manual verification}

## Linked Issue

Closes #{issue_number}
```

**Rules** (from `prompts/build.txt` "Traceability"):
- PR title: `{task-id}: {description}` — never bare descriptions
- Exactly ONE `Closes #NNN` — for the issue the PR directly solves
- Context references: use `Related: #NNN` or `See #NNN`, never `Closes`

## Review Comment Template

For triage reviews and code review feedback:

```markdown
## Review: {Approved / Needs Changes / Decline}

### Assessment
| Check | Status | Notes |
|-------|--------|-------|
| {criterion} | {pass/fail} | {detail} |

### Tier Classification
**Recommended:** `tier:{tier}`
**Rationale:** {why — e.g., "single-file fix with exact code suggestion → tier:simple"}

### Implementation Guidance
{Actionable steps for the worker, not abstract advice}
- File: `{path:line}`
- Change: {exact description or code block}
```
