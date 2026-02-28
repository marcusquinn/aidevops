---
description: Review session for completeness, best practices, and knowledge capture
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  task: true
---

# Session Review - Completeness and Best Practices Audit

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Review current session for completeness, workflow adherence, and knowledge capture
- **Trigger**: `/session-review` command, end of significant work, before ending session
- **Output**: Structured assessment with actionable next steps

**Review Categories**:
1. Objective completion - all goals achieved?
2. Workflow adherence - aidevops best practices followed?
3. Conversation value extraction - all insight, direction, and value captured?
4. Knowledge capture - learnings documented?
5. Session health - time to end or continue?

**Key Outputs**:
- Completion score (0-100%)
- Outstanding items list
- Conversation value extraction report
- Knowledge capture recommendations
- Session continuation advice

<!-- AI-CONTEXT-END -->

## Command Usage

```bash
/session-review [focus]
```

**Arguments**:
- `focus` (optional): Specific area to review (objectives, workflow, knowledge, all)

**Examples**:

```bash
/session-review              # Full review
/session-review objectives   # Focus on goal completion
/session-review workflow     # Focus on best practices
/session-review knowledge    # Focus on learnings capture
```

## Review Process

### Step 1: Gather Session Context

Collect information about the current session:

```bash
# Check current branch and recent commits
git branch --show-current
git log --oneline -10

# Check TODO.md for session tasks
grep -A 20 "## In Progress" TODO.md 2>/dev/null || echo "No TODO.md"

# Check for uncommitted changes
git status --short

# Check for active Ralph loop (new location, then legacy)
test -f .agents/loop-state/ralph-loop.local.md && cat .agents/loop-state/ralph-loop.local.md | head -10 || \
test -f .claude/ralph-loop.local.md && cat .claude/ralph-loop.local.md | head -10

# Check recent PR activity
gh pr list --state open --limit 5 2>/dev/null || echo "No open PRs"
```

### Step 2: Objective Completion Assessment

Evaluate what was accomplished:

| Check | Method | Weight |
|-------|--------|--------|
| Initial request fulfilled | Compare first message to current state | 40% |
| TODO items completed | Count `[x]` vs `[ ]` in session scope | 20% |
| Branch purpose achieved | Compare branch name to commits | 20% |
| Tests passing (if applicable) | Run test suite | 10% |
| No blocking errors | Check for unresolved issues | 10% |

**Output format**:

```text
## Objective Completion: {score}%

### Completed
- [x] {objective 1}
- [x] {objective 2}

### Outstanding
- [ ] {remaining item 1} - {reason/blocker}
- [ ] {remaining item 2} - {next step needed}

### Scope Changes
- {any scope additions or reductions during session}
```

### Step 3: Workflow Adherence Check

Verify aidevops best practices were followed:

| Practice | Check | Status |
|----------|-------|--------|
| Pre-edit git check | On feature branch, not main | Required |
| TODO tracking | Tasks logged in TODO.md | Recommended |
| Commit hygiene | Atomic commits, clear messages | Required |
| Quality checks | Linters run before commit | Recommended |
| Issue-sync | `issue-sync-helper.sh status` after PR merge | Recommended |
| Documentation | Changes documented where needed | Situational |

**Check commands**:

```bash
# Verify not on main
[[ "$(git branch --show-current)" != "main" ]] && echo "OK: Feature branch" || echo "WARN: On main"

# Check commit message quality
git log --oneline -5 | while read line; do
    [[ ${#line} -gt 10 ]] && echo "OK: $line" || echo "WARN: Short message"
done

# Check for TODO.md updates
git diff --name-only HEAD~5 | grep -q "TODO.md" && echo "OK: TODO.md updated" || echo "INFO: No TODO.md changes"
```

**Output format**:

```text
## Workflow Adherence

### Followed
- [x] Working on feature branch: {branch-name}
- [x] Commits are atomic and descriptive
- [x] {other practices followed}

### Missed
- [ ] {practice missed} - {recommendation}

### Recommendations
- {specific improvement for next session}
```

### Step 4: Auto-Distill Session Learnings

**MANDATORY**: Run session distillation to automatically extract and store learnings:

```bash
~/.aidevops/agents/scripts/session-distill-helper.sh auto
```

This will:
1. Analyze git commits for patterns (fixes, features, refactors)
2. Extract learnings with appropriate types (ERROR_FIX, WORKING_SOLUTION, etc.)
3. Store them to memory automatically

### Step 5: Conversation Value Extraction

**MANDATORY**: Re-read the entire conversation from the beginning. Auto-distill (Step 4) only captures what made it into git commits. The conversation itself contains insights, user direction, design decisions, and observations that may not have been captured in any artifact.

**What to look for:**

| Signal | Example | Capture To |
|--------|---------|------------|
| User direction or philosophy | "always look to solve root causes" | Agent docs, memory |
| Design decisions with rationale | "POC mode is a flag, not a separate system" | PLANS.md, brief, memory |
| Observations about system behaviour | "the pulse completed 8 tasks in 40 min" | Memory |
| Root cause analyses | "workers search by keyword instead of using authoritative ID" | Code fix + memory |
| Patterns that recur | "three-layer defense: prevent, detect, correct" | Agent docs, memory |
| User preferences or constraints | "skip ceremony for prototypes" | Memory |
| Unfinished threads | "we should also check X" — but never did | TODO.md or issue |
| Side discoveries | "GitHub parses Closes #NNN in prose text" | Docs, memory |
| Implicit standards | user corrects an approach — that correction is a standard | Agent docs |

**Process:**

1. Scan the conversation chronologically for each signal type above
2. For each finding, check: is this already captured in a commit, PR, memory, TODO, or doc?
3. If not captured: capture it now (store to memory, add to docs, create a TODO, or file an issue)
4. If partially captured: verify the capture is complete and accurate
5. Pay special attention to user corrections and redirections — these reveal gaps in the framework's defaults

**The goal is zero knowledge loss.** Every insight from the conversation should be traceable to at least one artifact. A session that produced good work but lost the reasoning behind it has failed at knowledge capture.

**Output format:**

```text
## Conversation Value Extraction

### Newly Captured
- {insight}: stored to {location} (memory/docs/TODO/issue)

### Already Captured
- {insight}: found in {location}

### Unfinished Threads
- {thread}: created {TODO/issue} for follow-up
```

### Step 6: Knowledge Capture Assessment

Identify learnings that should be preserved beyond what auto-distill and conversation extraction captured:

| Knowledge Type | Capture Location | Priority |
|----------------|------------------|----------|
| Bug patterns discovered | Code comments, docs | High |
| Workflow improvements | Agent files, AGENTS.md | High |
| Tool discoveries | Relevant subagent | Medium |
| User preferences | memory/ files | Medium |
| Temporary workarounds | TODO.md, code comments | Low |

**Questions to assess**:

1. Did the AI make any mistakes that were corrected?
2. Were any new patterns or approaches discovered?
3. Did any tools or commands not work as expected?
4. Were there any "aha" moments worth preserving?
5. Did the user express preferences worth remembering?

**Output format**:

```text
## Knowledge Capture

### Should Document
- {learning 1}: Suggest adding to {location}
- {learning 2}: Suggest adding to {location}

### Already Captured
- {item already in code/docs}

### User Preferences Noted
- {preference to remember for future sessions}
```

### Step 7: Session Health Assessment

Determine if session should continue or end:

| Signal | Indicates | Recommendation |
|--------|-----------|----------------|
| All objectives complete | Session success | End session |
| PR merged | Major milestone | End or new session |
| Context becoming stale | Long session | End session |
| Topic shift requested | New focus needed | New session |
| Blocked on external | Waiting required | End session |
| More work in scope | Continuation | Continue |

**Output format**:

```text
## Session Health

**Status**: {Continue | End Recommended | End Required}
**Reason**: {explanation}

### If Ending Session
1. {final action 1 - e.g., commit remaining changes}
2. {final action 2 - e.g., update TODO.md}
3. {final action 3 - e.g., run @agent-review}

### If Continuing
- Next focus: {what to work on next}
- Estimated remaining: {time estimate}

### For New Sessions
- {topic 1}: {brief description} - suggest branch: {type}/{name}
- {topic 2}: {brief description} - suggest branch: {type}/{name}
```

## Complete Review Output Template

```text
# Session Review

**Branch**: {branch-name}
**Duration**: {approximate session length}
**Date**: {YYYY-MM-DD}

---

## Objective Completion: {score}%

### Completed
{list}

### Outstanding
{list}

---

## Workflow Adherence

### Followed
{list}

### Improvements Needed
{list}

---

## Conversation Value Extraction

### Newly Captured
{insights stored to memory/docs/TODO/issues during this review}

### Already Captured
{insights already in artifacts}

### Unfinished Threads
{threads that need follow-up TODOs or issues}

---

## Knowledge Capture

### Should Document
{list with locations}

### Action Items
{specific documentation tasks}

---

## Session Recommendation

**Verdict**: {Continue | End Session | Start New Session}

### Immediate Actions
1. {action 1}
2. {action 2}
3. {action 3}

### For Future Sessions
{list of topics/tasks to start fresh}

---

*Review generated by /session-review*
```

## Integration with Other Workflows

### Before PR Creation

Run `/session-review` before creating a PR to ensure:
- All intended changes are committed
- No outstanding items forgotten
- Documentation is complete

### Before Ending Session

Run `/session-review` to:
- Capture learnings via `@agent-review`
- Update TODO.md with any discovered tasks
- Check issue-sync drift: `issue-sync-helper.sh status` (t179.4)
- Ensure clean handoff for future sessions

### After Ralph Loop Completion

When a Ralph loop completes, `/session-review` helps:
- Verify the completion promise was truly met
- Identify any cleanup needed
- Suggest next steps

## Related

- `workflows/session-manager.md` - Session lifecycle management
- `tools/build-agent/agent-review.md` - Agent improvement process
- `workflows/preflight.md` - Pre-commit quality checks
- `workflows/postflight.md` - Post-release verification
