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

<!-- AI-CONTEXT-END -->

## Session Completion Detection

| Signal | Detection | Confidence |
|--------|-----------|------------|
| Tasks complete | `grep -c '^\s*- \[ \]' TODO.md` returns 0 | High |
| PR merged | `gh pr view --json state` returns "MERGED" | High |
| Release published | `gh release view` succeeds for new version | High |
| User gratitude | "thanks", "done", "that's all", "finished" | Medium |
| Topic shift | New unrelated task requested | Medium |

```bash
check_session_status() {
    local incomplete
    local pr_state

    incomplete=$(grep -c '^\s*- \[ \]' TODO.md 2>/dev/null || echo "0")
    pr_state=$(gh pr view --json state --jq '.state' 2>/dev/null || echo "none")

    echo "Incomplete tasks: ${incomplete} | PR state: ${pr_state}"

    if [[ "${incomplete}" == "0" && "${pr_state}" == "MERGED" ]]; then
        echo "Session complete. Consider: 1) @agent-review  2) New session"
    fi

    return 0
}
```

## Suggestion Templates

Use these templates at session boundaries. Replace `{placeholders}` with actual values.

```text
---
Session status: {completed items summary}

Suggestions:
1. Run @agent-review to capture learnings
2. Start new session for next task (clean context)
3. Spawn parallel session: worktree-helper.sh add feature/{next-feature}
---
```

**Trigger-specific prefixes:**

| Trigger | Prefix line |
|---------|-------------|
| PR merge + release | `[x] {PR title} (PR #{number} merged), v{version} released` |
| Topic shift | `Topic shift: {new topic} differs from {current focus} — new session recommended` |
| Context window | `Long session with significant context — risk of degradation` |

## Spawning New Sessions

### Worktree + New Session (Recommended)

```bash
# Create worktree and spawn session
~/.aidevops/agents/scripts/worktree-helper.sh add feature/parallel-task
# Output: ~/Git/<project>-feature-parallel-task/

# macOS Terminal.app
osascript -e 'tell application "Terminal" to do script "cd ~/Git/<project>-feature-parallel-task && opencode"'

# iTerm (responds to both "iTerm" and "iTerm2")
osascript -e 'tell application "iTerm" to tell current window to create tab with default profile command "cd ~/Git/<project>-feature-parallel-task && opencode"'
```

### Background / Headless

```bash
opencode run "Continue with task X" --agent Build+ &

# Persistent server for multiple sessions
opencode serve --port 4097 &
opencode run --attach http://localhost:4097 "Task description" --agent Build+
```

### Linux Terminals

```bash
gnome-terminal --tab -- bash -c "cd ~/Git/<project> && opencode; exec bash"
konsole --new-tab -e bash -c "cd ~/Git/<project> && opencode"
kitty @ launch --type=tab --cwd=~/Git/<project> opencode
```

## Session Handoff

Export context for continuation sessions:

```bash
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

opencode run "Read .session-handoff.md and continue the work" --agent Build+
```

## When to Suggest @agent-review

1. **After PR merge** — document what worked
2. **After release** — document release learnings
3. **After fixing multiple issues** — pattern recognition opportunity
4. **After user correction** — immediate improvement opportunity
5. **Before unrelated work** — clean context boundary
6. **After long session** — document accumulated learnings

## Loop Agent Integration

Loop agents (`/preflight-loop`, `/pr-loop`, `/postflight-loop`) should detect completion, suggest @agent-review or new session, and offer spawning for the next task.

## Compaction Resilience (Long Autonomous Sessions)

During 1h+ sessions, context compaction can lose task state. Use checkpoints to persist state to disk.

### Checkpoint Workflow

```bash
# Save after completing each task
session-checkpoint-helper.sh save \
  --task "t135.9" \
  --next "t135.11,t014,t025" \
  --worktree "/path/to/worktree" \
  --batch "batch2-quality" \
  --note "Completed trap cleanup for 29 scripts" \
  --elapsed "90" --target "240"

# Reload before starting any new task (especially after compaction)
session-checkpoint-helper.sh load

# Check staleness
session-checkpoint-helper.sh status
```

### When to Checkpoint

| Event | Action |
|-------|--------|
| Task completed | `save` with updated --task and --next |
| PR created/merged | `save` with --note describing PR state |
| Batch committed | `save` with --note listing changes |
| Before large operation | `save` as recovery point |
| After context compaction | `load` to re-orient |

### Self-Prompting Loop (Interactive Only)

For autonomous multi-hour sessions (NOT headless workers):

1. Mark task complete in TODO.md
2. Save checkpoint to disk
3. Re-read checkpoint (forces re-orientation after compaction)
4. Read TODO.md for next task
5. Start next task

### Continuation Prompt

```bash
# Generate continuation prompt for pasting into new session
session-checkpoint-helper.sh continuation

# Auto-save with state detection
session-checkpoint-helper.sh auto-save --task "t135.9" --note "Completed X"

# Include in session distillation
session-distill-helper.sh auto        # Includes checkpoint step
session-distill-helper.sh checkpoint  # Just operational state
```

Gathers state from: git (branch, uncommitted changes, commits, worktrees), GitHub (open PRs), supervisor (batch state), TODO.md (in-progress tasks), checkpoint file, and memory. This is the single highest-impact factor for session continuity — AGENTS.md provides the "how", the continuation prompt provides the "where we are".

## Related

**AGENTS.md is the single source of truth for agent behavior.** This document is supplementary.

- `AGENTS.md` — Root agent instructions (authoritative)
- `workflows/worktree.md` — Parallel branch development
- `workflows/ralph-loop.md` — Iterative development loops
- `tools/build-agent/agent-review.md` — Session review process
- `tools/opencode/opencode.md` — OpenCode CLI reference
