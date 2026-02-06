---
description: Session lifecycle management and parallel work coordination
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

# Session Manager

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Detect session completion, suggest new sessions, spawn parallel work
- **Triggers**: PR merge, release, topic shift, context limits
- **Actions**: Suggest @agent-review, new session, worktree + spawn

**Key signals for session completion:**
- All session tasks marked `[x]` in TODO.md
- PR merged (`gh pr view --json state`)
- Release published (`gh release view`)
- User gratitude phrases
- Topic shift to unrelated work

<!-- AI-CONTEXT-END -->

## Session Completion Detection

### Automatic Signals

| Signal | Detection Method | Confidence |
|--------|------------------|------------|
| Tasks complete | `grep -c '^\s*- \[ \]' TODO.md` returns 0 | High |
| PR merged | `gh pr view --json state` returns "MERGED" | High |
| Release published | `gh release view` succeeds for new version | High |
| User gratitude | "thanks", "done", "that's all", "finished" | Medium |
| Topic shift | New unrelated task requested | Medium |

### Check Script

```bash
# Check session completion status
check_session_status() {
    echo "=== Session Status ==="
    
    # Check incomplete tasks
    local incomplete
    incomplete=$(grep -c '^\s*- \[ \]' TODO.md 2>/dev/null || echo "0")
    echo "Incomplete tasks: $incomplete"
    
    # Check recent PR
    local pr_state
    pr_state=$(gh pr view --json state --jq '.state' 2>/dev/null || echo "none")
    echo "Current PR state: $pr_state"
    
    # Check latest release vs VERSION
    local version latest_tag
    version=$(cat VERSION 2>/dev/null || echo "unknown")
    latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "none")
    echo "VERSION: $version, Latest tag: $latest_tag"
    
    # Suggest if complete
    if [[ "$incomplete" == "0" && "$pr_state" == "MERGED" ]]; then
        echo ""
        echo "Session appears complete. Consider:"
        echo "  1. Run @agent-review"
        echo "  2. Start new session"
    fi
}
```

## Suggestion Templates

### After PR Merge + Release

```text
---
Session goals achieved:
- [x] {PR title} (PR #{number} merged)
- [x] v{version} released

Suggestions:
1. Run @agent-review to capture learnings
2. Start new session for next task (clean context)
3. Continue in current session

For parallel work on related feature:
  worktree-helper.sh add feature/{next-feature}
---
```

### Topic Shift Detected

```text
---
Topic shift detected: {new topic} differs from {current focus}

Suggestions:
1. Start new session for {new topic} (recommended)
2. Create worktree for parallel work
3. Continue in current session (context may become unfocused)
---
```

### Context Window Warning

When conversation becomes very long:

```text
---
This session has been running for a while with significant context.

Suggestions:
1. Run @agent-review to capture session learnings
2. Start new session with fresh context
3. Continue (risk of context degradation)
---
```

## Spawning New Sessions

### Option 1: New Terminal Tab (macOS)

```bash
# macOS Terminal.app
spawn_terminal_tab() {
    local dir="${1:-$(pwd)}"
    local cmd="${2:-opencode}"
    osascript -e "tell application \"Terminal\" to do script \"cd '$dir' && $cmd\""
}

# iTerm
spawn_iterm_tab() {
    local dir="${1:-$(pwd)}"
    local cmd="${2:-opencode}"
    osascript -e "tell application \"iTerm\" to tell current window to create tab with default profile command \"cd '$dir' && $cmd\""
}

# Usage
spawn_terminal_tab ~/Git/project-feature-auth
```

### Option 2: Background Session

```bash
# Non-interactive execution
opencode run "Continue with task X" --agent Build+ &

# Persistent server for multiple sessions
opencode serve --port 4097 &
opencode run --attach http://localhost:4097 "Task description" --agent Build+
```

### Option 3: Worktree + New Session (Recommended)

Best for parallel branch work:

```bash
# Create worktree
~/.aidevops/agents/scripts/worktree-helper.sh add feature/parallel-task
# Output: ~/Git/project-feature-parallel-task/

# Spawn session in worktree (macOS)
osascript -e 'tell application "Terminal" to do script "cd ~/Git/project-feature-parallel-task && opencode"'
```

### Linux Terminal Spawning

```bash
# GNOME Terminal
gnome-terminal --tab -- bash -c "cd ~/Git/project && opencode; exec bash"

# Konsole
konsole --new-tab -e bash -c "cd ~/Git/project && opencode"

# Kitty
kitty @ launch --type=tab --cwd=~/Git/project opencode
```

## Session Handoff Pattern

When spawning a continuation session:

```bash
# Export context for new session
cat > .session-handoff.md << EOF
# Session Handoff

**Previous session**: $(date)
**Branch**: $(git branch --show-current)
**Last commit**: $(git log -1 --oneline)

## Completed
- {list completed items}

## Continue With
- {next task description}

## Context
- {relevant context for continuation}
EOF

# Spawn with handoff
opencode run "Read .session-handoff.md and continue the work" --agent Build+
```

## When to Suggest @agent-review

Agents should suggest `@agent-review` at these points:

1. **After PR merge** - Capture what worked in the PR process
2. **After release** - Capture release learnings
3. **After fixing multiple issues** - Pattern recognition opportunity
4. **After user correction** - Immediate improvement opportunity
5. **Before starting unrelated work** - Clean context boundary
6. **After long session** - Capture accumulated learnings

## Integration with Loop Agents

Loop agents (`/preflight-loop`, `/pr-loop`, `/postflight-loop`) should:

1. **Detect completion** - When loop succeeds (all checks pass, PR merged, etc.)
2. **Suggest next steps** - Offer @agent-review or new session
3. **Offer spawning** - For parallel work on next task

Example loop completion:

```text
<promise>PR_MERGED</promise>

---
Loop complete. PR #123 merged successfully.

Suggestions:
1. Run @agent-review to capture PR process learnings
2. Start new session for next task
3. Spawn parallel session: worktree-helper.sh add feature/next-feature
---
```

## Related

**AGENTS.md is the single source of truth for agent behavior.** This document is supplementary and defers to AGENTS.md where they differ.

- `AGENTS.md` - Root agent instructions (authoritative)
- `workflows/worktree.md` - Parallel branch development
- `workflows/ralph-loop.md` - Iterative development loops
- `tools/build-agent/agent-review.md` - Session review process
- `tools/opencode/opencode.md` - OpenCode CLI reference
