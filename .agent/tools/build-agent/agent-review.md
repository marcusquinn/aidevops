---
description: Systematic review and improvement of agent instructions
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Agent Review - Reviewing and Improving Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Systematic review and improvement of agent instructions
- **Trigger**: End of session, user correction, observable failure
- **Output**: Proposed improvements with evidence and scope

**Review Checklist**:
1. Instruction count - over budget?
2. Universal applicability - task-specific content?
3. Duplicate detection - same guidance elsewhere?
4. Code examples - still accurate? authoritative?
5. AI-CONTEXT block - captures essentials?

**Self-Assessment Triggers**:
- User corrects agent response
- Commands/paths fail
- Contradiction with authoritative sources
- Staleness indicators (versions, deprecated APIs)

**Process**: Complete task first, cite evidence, check duplicates, propose specific fix, ask permission

**Testing**: Use OpenCode CLI to test agent/config changes without restarting TUI:

```bash
opencode run "Test query" --agent [agent-name]
```text

See `tools/opencode/opencode.md` for CLI testing patterns.

<!-- AI-CONTEXT-END -->

## Agent Review Process

### When to Review

1. **End of significant session** - After complex multi-step tasks
2. **User correction** - Immediate trigger for targeted review
3. **Observable failure** - Commands fail, paths don't exist
4. **Periodic maintenance** - Scheduled review cycles

### When Agents Should Suggest @agent-review

All agents should suggest calling `@agent-review` at these points:

1. **After PR merge** - Capture what worked in the PR process
2. **After release** - Document release learnings
3. **After fixing multiple issues** - Pattern recognition opportunity
4. **After user correction** - Immediate improvement opportunity
5. **Before starting unrelated work** - Clean context boundary
6. **After long session** - Capture accumulated learnings

**Suggestion format:**

```text
---
Session complete. Consider running @agent-review to:
- Capture patterns from {specific accomplishment}
- Identify improvements to {agents used}
- Document {any corrections or failures}

Options:
1. Run @agent-review now
2. Start new session (clean context)
3. Continue in current session
---
```

See `workflows/session-manager.md` for full session lifecycle guidance.

### Review Checklist

For each agent file under review:

#### 1. Instruction Count

- Count discrete instructions (bullets, rules, directives)
- Target: <50 for main agents, <100 for detailed subagents
- If over budget: consolidate, move to subagent, or remove

#### 2. Universal Applicability

- Is every instruction relevant to >80% of tasks?
- Task-specific content should move to subagents
- Check for edge cases that became main content

#### 3. Duplicate Detection

```bash
# Search for similar instructions across all agents
rg "pattern" .agent/

# Check specific files that might overlap
diff .agent/file1.md .agent/file2.md
```text

- Same concept should have single authoritative source
- Cross-references okay, duplicated instructions not okay

#### 4. Code Examples Audit

For each code example:
- Is it authoritative (the reference implementation)?
- Does it still work? Test if possible
- Are secrets properly placeholder'd?
- Could it be a `file:line` reference instead?

#### 5. AI-CONTEXT Block Quality

- Does condensed version capture all essentials?
- Is it readable without the detailed section?
- Would an AI get stuck with only the AI-CONTEXT?

#### 6. Slash Command Audit

- Are any commands defined inline in main agents?
- Should inline commands move to `scripts/commands/` or domain subagent?
- Do main agents only reference commands (not implement them)?

### Improvement Proposal Format

When proposing changes:

```markdown
## Agent Improvement Proposal

**File**: `.agent/[path]/[file].md`
**Issue**: [Brief description]
**Evidence**: [Specific failure, contradiction, or user feedback]

**Related Files** (checked for duplicates):
- `.agent/[other-file].md` - [relationship]
- `.agent/[another-file].md` - [relationship]

**Proposed Change**:
[Specific before/after or description]

**Impact Assessment**:
- [ ] No conflicts with other agents
- [ ] Instruction count impact: [+/- N]
- [ ] Tested if code example
```text

### Common Improvement Patterns

#### Consolidating Instructions

```markdown
# Before (5 instructions)
- Use local variables
- Assign parameters to locals
- Never use $1 directly
- Pattern: local var="$1"
- This prevents issues

# After (1 instruction)
- Pattern: `local var="$1"` for all parameters
```text

#### Moving to Subagent

```markdown
# Before (in main AGENTS.md)
## Database Schema Guidelines
[50 lines of detailed rules]

# After (in AGENTS.md)
See `aidevops/architecture.md` for schema guidelines

# After (in architecture.md)
## Database Schema Guidelines
[50 lines of detailed rules]
```text

#### Replacing Code with Reference

```markdown
# Before
Here's the error handling pattern:
```bash
if ! result=$(command); then
    echo "Error: $result"
    return 1
fi
```text

## After

See error handling pattern at `.agent/scripts/hostinger-helper.sh:145`

```text

### Session Review Workflow

At end of significant session:

1. **Note any corrections** - What did user correct?
2. **Note any failures** - What didn't work as expected?
3. **Check instructions used** - Which agents were relevant?
4. **Propose improvements** - Following format above
5. **Ask permission** - User decides if changes are made

### Contributing Improvements

Improvements to aidevops agents benefit all users:

1. Create improvement proposal
2. Make changes in `~/Git/aidevops/`
3. Run quality check: `.agent/scripts/linters-local.sh`
4. Commit with descriptive message
5. Create PR to upstream

See `workflows/release-process.md` for contribution workflow.
