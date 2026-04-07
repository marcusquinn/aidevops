---
description: Centralised structured content composition — all agents writing GitHub content (issues, briefs, comments, PR descriptions, escalation reports) use this for consistent, tier-optimised, actionable output
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Brief Composition Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Single source of truth for all GitHub-written content — briefs, issue bodies, PR descriptions, comments, escalation reports
- **Key principle**: Every piece of written output is mentorship for the next reader (human or model). Transfer the knowledge they need to succeed.
- **Evidence**: 47-PR research corpus — 100% Haiku success with exact oldString/newString, 0% with descriptive prose.
- **Template**: `templates/brief-template.md`
- **Escalation template**: `templates/escalation-report-template.md`
- **Tier criteria**: `reference/task-taxonomy.md`

<!-- AI-CONTEXT-END -->

## Core Rule

**The brief IS the product.** A vague brief dispatched to Opus wastes more money than a prescriptive brief dispatched to Haiku. Invest the effort in the brief, not the worker.

## Tier Classification

Assess every work item against these empirical criteria (from 47-PR research):

| Criterion | tier:simple | tier:standard | tier:reasoning |
|-----------|------------|---------------|----------------|
| **Files** | Single file | 2-3 files with coordination | 4+ files or architectural |
| **Lines changed** | Under 100 | 100-500 | 500+ or novel design |
| **Pattern** | Follows existing pattern | Adapts pattern to new context | Creates new pattern |
| **Code provided** | Exact oldString/newString | Skeletons with signatures | Approach description |
| **Judgment needed** | None — mechanical execution | Error recovery, approach selection | Design decisions, trade-offs |
| **Examples** | Review feedback, config tweaks, quote fixes, docs additions | Bug fixes, refactors, feature impl | Architecture, security audits |

**Default to `tier:simple` and verify the brief meets it.** Only escalate when the brief genuinely cannot provide exact code.

## The Mentorship Principle

Every piece of GitHub-written content mentors the next reader. Apply these checks:

| Question | If NO → fix |
|----------|-------------|
| Does this tell the reader WHERE to look? | Add file paths with line ranges |
| Does this tell the reader WHAT to do? | Add exact code or clear steps |
| Does this tell the reader HOW to verify? | Add verification commands |
| Does this tell the reader WHEN they are done? | Add a concrete completion signal |
| Does this tell the reader WHAT to do when stuck? | Add fallback/recovery steps |
| Does this tell the reader WHAT was already tried? | Add prior attempt context (escalation, kill comments) |
| Could a cheaper model execute this? | Make it more prescriptive |

A dispatch comment that says "implement issue #42" teaches nothing. One that says "edit `src/auth.ts:45` — replace `([^0-9]|$)` with `\b` — verify with `shellcheck src/auth.ts`" enables tier:simple dispatch.

## Headless Continuation Resilience

Briefs consumed by headless workers must anticipate that the worker will encounter empty results, wrong paths, and ambiguous states. Every brief section should answer: "what does the worker do when this step produces nothing?"

**Completion signal (mandatory for all tiers):** Every issue body must include a `### Done When` section with a concrete, machine-verifiable condition. Without this, workers explore indefinitely or stop prematurely.

```markdown
### Done When

- `shellcheck .agents/scripts/{file}.sh` exits 0
- `gh pr view --json state` shows MERGED
- The issue is closed with a closing comment linking the PR
```

**Recovery paths (mandatory for tier:standard and above):** For each implementation step, include what to do if the expected file/function/pattern is not found:

```markdown
### Implementation Steps

1. Read `.agents/scripts/pulse-wrapper.sh:4254` — the `auto_approve_maintainer_issues()` function
   - **If not found at that line:** `grep -n 'auto_approve_maintainer_issues' .agents/scripts/pulse-wrapper.sh`
   - **If function was renamed/removed:** check `git log --oneline -5 .agents/scripts/pulse-wrapper.sh` for recent changes
```

**Empty-result fallbacks:** When a brief references a file path, include a fallback search so the worker doesn't stop on first miss:

```markdown
- EDIT: `.agents/scripts/memory-pressure-monitor.sh:877-888`
  - Fallback: `grep -n 'cmd_daemon' .agents/scripts/memory-pressure-monitor.sh`
```

## How to Use This Agent

- **Routing**: See `brief/routing.md` for when to use this agent (work item creation, comments, PR descriptions)
- **Tier-specific formats**:
  - `tier:simple` → `brief/tier-simple.md` (prescriptive, exact code blocks)
  - `tier:standard` → `brief/tier-standard.md` (skeletons, judgment required)
  - `tier:reasoning` → `brief/tier-reasoning.md` (problem space, constraints)
- **Templates**: `brief/templates.md` (issue body, comments, PR description, review comment)

## Callers: How to Reference This Agent

Agents that write GitHub content should include a pointer rather than duplicating formatting rules:

```markdown
Format the {finding/brief/issue body/comment/PR description} using `workflows/brief.md`
for the classified tier. Load on demand — do not inline the format rules.
```

## Related

- `templates/brief-template.md` — Full task brief template (for `/define`, `/new-task`)
- `templates/escalation-report-template.md` — Failure report format for cascade dispatch
- `reference/task-taxonomy.md` — Tier definitions, cascade model, escalation reasons
- `tools/build-agent/build-agent.md` — "Designing tier-aware output" section
- `tools/code-review/code-simplifier.md` — Primary consumer for simplification issues
- `prompts/build.txt` — Traceability rules, signature footer, PR title format
