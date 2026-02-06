---
name: beads
description: This subagent should only be called manually by the user.
mode: subagent
---

# Beads - Task Graph Visualization

Task dependency tracking and graph visualization for TODO.md and PLANS.md.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `bd` | Beads CLI |
| `bd init` | Initialize Beads in project |
| `bd create "task"` | Create a task |
| `bd list` | List all tasks |
| `bd ready` | Show tasks with no blockers |
| `bd graph <id>` | Show dependency graph for issue |
| `bd dep add <id2> <id1>` | Make id2 depend on id1 |
| `bd close <id>` | Close a task |
| `beads-sync-helper.sh push` | Sync TODO.md → Beads |
| `beads-sync-helper.sh pull` | Sync Beads → TODO.md |
| `todo-ready.sh` | Show unblocked tasks (from TODO.md) |

## Architecture

```text
TODO.md / PLANS.md (source of truth)
         ↓ push
    .beads/beads.db (SQLite + JSONL)
         ↓
    Graph visualization (bd CLI, TUIs)
```

**Key principle**: aidevops markdown files are the source of truth. Beads syncs from them.

## Task ID Format

```markdown
- [ ] t001 Task description
- [ ] t001.1 Subtask of t001
- [ ] t001.1.1 Sub-subtask
```

## Dependency Syntax

```markdown
- [ ] t002 Implement feature blocked-by:t001
- [ ] t003 Deploy blocks:t004,t005
```

| Syntax | Meaning |
|--------|---------|
| `blocked-by:t001` | This task waits for t001 |
| `blocked-by:t001,t002` | Waits for multiple tasks |
| `blocks:t003` | This task blocks t003 |

## Sync Commands

### Push (TODO.md → Beads)

```bash
# Sync current project
~/.aidevops/agents/scripts/beads-sync-helper.sh push

# Sync specific project
~/.aidevops/agents/scripts/beads-sync-helper.sh push /path/to/project
```

### Pull (Beads → TODO.md)

```bash
# Pull changes from Beads
~/.aidevops/agents/scripts/beads-sync-helper.sh pull
```

### Status

```bash
# Check sync status
~/.aidevops/agents/scripts/beads-sync-helper.sh status
```

## Ready Tasks

Show tasks with no open blockers:

```bash
# List ready tasks
~/.aidevops/agents/scripts/todo-ready.sh

# JSON output
~/.aidevops/agents/scripts/todo-ready.sh --json

# Count only
~/.aidevops/agents/scripts/todo-ready.sh --count
```

## Beads CLI Commands

```bash
# Initialize
bd init

# Create task
bd create "Implement login"

# Create with description
bd create "Deploy" --description="Deploy to production"

# Add dependency (issue2 depends on issue1)
bd dep add <issue2-id> <issue1-id>

# List tasks
bd list
bd list --status open

# Show graph for an issue
bd graph <issue-id>

# Show ready tasks (no blockers)
bd ready

# Close task
bd close <id>

# MCP server (for AI tools)
bd mcp
```

## Conflict Resolution

When both TODO.md and Beads have changes:

1. **Warning displayed** - sync detects conflict
2. **Manual resolution** - review both sources
3. **Force push** - `beads-sync-helper.sh push --force`
4. **Force pull** - `beads-sync-helper.sh pull --force`

## Viewers

| Tool | Type | Features | Install |
|------|------|----------|---------|
| `bd` | CLI | Core commands, MCP server | `brew install steveyegge/beads/bd` |
| `bv` | TUI | PageRank, critical path, graph analytics | `brew install dicklesworthstone/tap/bv` |
| `beads-ui` | Web | Live updates, browser-based | `npm install -g beads-ui` |
| `bdui` | TUI | React/Ink interface | `npm install -g bdui` |
| `perles` | TUI | BQL query language | `cargo install perles` |

### Viewer Installation

```bash
# Core CLI (required)
brew install steveyegge/beads/bd
# Or: go install github.com/steveyegge/beads/cmd/bd@latest

# Advanced TUI with graph analytics (Go)
brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv
# Or: go install github.com/Dicklesworthstone/beads_viewer/cmd/bv@latest
# Or: curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh | bash
# Repository: https://github.com/Dicklesworthstone/beads_viewer

# Web UI with live updates (Node.js)
npm install -g beads-ui
# Or run locally: npx beads-ui
# Repository: https://github.com/mantoni/beads-ui

# React/Ink TUI (Node.js)
npm install -g bdui
# Repository: https://github.com/assimelha/bdui

# BQL query language TUI (Rust)
cargo install perles
# Repository: https://github.com/zjrosen/perles
```

### Running Viewers

```bash
# Core CLI
bd list
bd ready
bd graph <issue-id>

# bv - Advanced TUI (beads_viewer)
bv                        # Interactive mode
bv --robot-triage         # Agent mode: triage overview
bv --robot-next           # Agent mode: next task to work on

# beads-ui - Web interface
beads-ui                  # Starts on http://localhost:3000
beads-ui --port 8080      # Custom port

# bdui - React/Ink TUI
bdui                      # Interactive mode

# perles - BQL queries
perles                    # Interactive REPL
perles "SELECT * FROM issues WHERE status = 'open'"
```

## Installation

```bash
# Homebrew (macOS/Linux)
brew install steveyegge/beads/bd

# Go
go install github.com/steveyegge/beads/cmd/bd@latest

# Or via aidevops setup
./setup.sh  # Installs bd automatically
```

## Project Initialization

```bash
# Enable beads in a project
aidevops init beads

# This:
# 1. Creates .beads/ directory
# 2. Runs bd init
# 3. Syncs existing TODO.md/PLANS.md
# 4. Adds .beads to .gitignore
```

## Integration with Workflows

### Task Lifecycle

Workflow commands automatically update task status:

```text
Ready/Backlog → In Progress → In Review → Done
   (branch)       (develop)      (PR)     (merge/release)
```

| Workflow | Task Status Change | TODO.md Section | Beads Action |
|----------|-------------------|-----------------|--------------|
| `/branch create` | → In Progress | Move to `## In Progress` | `beads-sync-helper.sh push` |
| `/pr create` | → In Review | Move to `## In Review` | `beads-sync-helper.sh push` |
| `/pr merge` | → Done | Move to `## Done` | `beads-sync-helper.sh push` |
| `/release` | → Done (all) | Move remaining to `## Done` | `beads-sync-helper.sh push` |

### Task Attributes by Stage

| Stage | Attributes Added |
|-------|------------------|
| In Progress | `started:2025-01-15T10:30Z` |
| In Review | `pr:123` or `pr_url:https://...` |
| Done | `completed:2025-01-16T14:00Z`, `actual:5h` |

### Git Workflow

```bash
# Before starting work
~/.aidevops/agents/scripts/todo-ready.sh  # See what's ready

# After creating branch
# Move task to ## In Progress, add started:, then:
~/.aidevops/agents/scripts/beads-sync-helper.sh push

# After creating PR
# Move task to ## In Review, add pr:, then:
~/.aidevops/agents/scripts/beads-sync-helper.sh push

# After merge/release
# Move task to ## Done, add completed: and actual:, then:
~/.aidevops/agents/scripts/beads-sync-helper.sh push
```

### Planning Workflow

1. Add tasks to TODO.md with dependencies
2. Run `/sync-beads` to update graph
3. Use `bd graph` to visualize
4. Run `/ready` to see unblocked tasks

### Slash Commands

| Command | Action |
|---------|--------|
| `/ready` | Show tasks with no blockers (Ready section) |
| `/sync-beads` | Sync TODO.md ↔ Beads |
| `/branch` | Create branch, move task to In Progress |
| `/pr` | Create PR, move task to In Review |
| `/release` | Release version, move tasks to Done |

## TOON Blocks

TODO.md includes TOON blocks for structured data:

```markdown
<!--TOON:dependencies-->
t002|blocked-by|t001
t003|blocks|t004
<!--/TOON:dependencies-->

<!--TOON:subtasks-->
t001|t001.1,t001.2
t001.1|t001.1.1
<!--/TOON:subtasks-->
```

## Troubleshooting

### Sync fails

```bash
# Check lock file
ls -la .beads/sync.lock

# Remove stale lock
rm .beads/sync.lock

# Check audit log
cat .beads/sync.log
```

### Beads not initialized

```bash
# Initialize manually
bd init

# Or reinitialize
rm -rf .beads && bd init
```

### Dependencies not showing

Ensure dependency syntax is correct:
- `blocked-by:t001` (no spaces around colon)
- Task IDs must exist
- Use comma for multiple: `blocked-by:t001,t002`
