<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Brief Composition Templates

Reference templates for GitHub-written content.

## Issue Body Template

When creating issues via `gh issue create`, format the body using the appropriate tier template, wrapped in standard issue structure:

```markdown
## Description

{1-2 sentence summary of what needs to change and why}

## Implementation

{Tier-appropriate content from tier-simple.md, tier-standard.md, or tier-reasoning.md}

## Acceptance Criteria

- [ ] {criterion with verify block if possible}
- [ ] Lint clean
- [ ] No unrelated changes
```

Always include tier label: `--label "tier:simple"` / `--label "tier:standard"` / `--label "tier:reasoning"`.

## Comment Templates

### Dispatch comment (pulse → worker)

Posted by the pulse when dispatching a worker. Gives the worker enough context to skip re-reading the issue body for orientation:

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

Posted when a worker is killed. Must mentor the next worker — not just state "timed out":

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

See `templates/escalation-report-template.md` for the full structured format. Must include:
1. What was attempted (files read, code tried)
2. Structured reason code (see template for taxonomy)
3. Discoveries reusable by the next tier
4. Brief gaps (what was missing or unclear)

## PR Description Template

Workers creating PRs use this structure. The description serves two audiences: the review bot (needs structured sections) and the human reviewer (needs motivation and evidence).

```markdown
## Summary

{1-3 bullet points: what changed and why}

## Changes

{For each file changed:}
- `{file_path}` — {what changed in this file}

## Verification

{Evidence that the change works:}
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
