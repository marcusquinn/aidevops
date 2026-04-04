<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gastown vs AI DevOps — Comparative Analysis

**Date**: 2026-03-16
**Analyst**: AI DevOps Framework
**Source**: https://github.com/steveyegge/gastown

---

## Executive Summary

Gastown (12.2k stars, 1k forks) is a multi-agent orchestration system for Claude Code with git-backed persistence. While philosophically similar to aidevops (both solve multi-agent coordination), gastown has a fundamentally different implementation approach that offers valuable lessons.

**Key Difference**: Gastown is a compiled Go binary with a structured domain model; aidevops is shell-script-based with intelligence-over-determinism philosophy.

---

## 1. Feature-by-Feature Comparison

### 1.1 Core Concepts Mapping

| Gastown | AI DevOps | Assessment |
|---------|-----------|------------|
| **Mayor** (AI coordinator) | `/pulse` supervisor | Gastown has a dedicated interactive coordinator agent; aidevops uses ephemeral pulse cycles |
| **Town** (`~/gt/`) | `~/.aidevops/` workspace | Similar workspace concept |
| **Rig** (project container) | Registered repos in `repos.json` | Gastown's rig wraps repos with agent management; aidevops tracks repos in JSON |
| **Polecats** (worker agents) | Workers dispatched via `opencode run` | Both ephemeral workers; gastown uses tmux sessions, aidevops uses `opencode run` |
| **Crew Members** | Interactive sessions | Both support personal workspaces |
| **Hooks** (git worktrees for persistence) | Standard git worktrees | Gastown elevates worktrees to first-class "hooks"; aidevops uses them transparently |
| **Convoys** (work bundling) | Task decomposition (t1408) | Gastown bundles at orchestration level; aidevops decomposes pre-dispatch |
| **Beads** (git-backed issues) | GitHub Issues + TODO.md | Gastown uses Dolt (Git for data); aidevops uses GitHub as state DB |

### 1.2 Unique Gastown Features (Not in AI DevOps)

| Feature | Description | aidevops Gap |
|---------|-------------|--------------|
| **Activity Feed TUI** (`gt feed`) | Real-time terminal dashboard with 3-panel view (Agent Tree, Convoy Panel, Event Stream) | `/dashboard` exists but no live TUI; mostly static reports |
| **Problems View** | Health state detection (GUPP violations, Stalled, Zombie, Working, Idle) | Stuck worker detection exists in pulse but less structured |
| **Formulas** | TOML-defined reusable workflows (`internal/formula/formulas/*.toml`) | No equivalent; each workflow is ad-hoc or shell-script based |
| **Web Dashboard** (`gt dashboard`) | Browser-based htmx auto-refresh dashboard | HTML dashboard generated but no auto-refresh; no command palette in browser |
| **GUPP Principle** | "If there is work on your Hook, YOU MUST RUN IT" | Implicit in `/full-loop` but not formalized as principle |
| **Mailboxes** | Formal inter-agent communication (`gt nudge`, mail system) | Cross-session memory only; no formal mailbox/message passing |
| **Multi-runtime support** | Claude, Codex, Cursor, Gemini, OpenCode, Copilot presets | Primary is Claude Code; others mentioned but less integrated |
| **Tmux integration** | Sessions managed via tmux windows/panes | No tmux integration; relies on `opencode` process management |
| **Beads (Dolt)** | Git-backed structured data store using Dolt database | Uses JSONL files and SQLite for memory; no Git-for-data |

### 1.3 Unique AI DevOps Features (Not in Gastown)

| Feature | Description | Gastown Gap |
|---------|-------------|-------------|
| **Quality Gates** | ShellCheck, SonarCloud, markdown linting on every edit | No mention of code quality enforcement |
| **Model Routing** | Cost-aware tier selection (haiku→flash→sonnet→pro→opus) | Runtime configured per-rig only |
| **Budget Tracking** | Daily spend tracking with proactive degradation | No cost management mentioned |
| **Skill System** | 25+ integrated service helpers with standardized patterns | Generic CLI commands only |
| **Pre-edit Git Check** | Prevents editing on main; enforces worktree workflow | No mention of main-branch protection |
| **Bundle Presets** | Project-type-aware defaults for quality gates | No project-type detection |
| **Contribution Watch** | Monitors external repos for reply-needed activity | External repo monitoring not mentioned |
| **Upstream Watch** | Tracks inspiration repos for new releases | No upstream monitoring |
| **Review Bot Gate** | CI check that waits for AI code review bots | No mention of review bot integration |
| **Task Decomposition** | Haiku-tier LLM classification of atomic vs composite tasks | All orchestration appears to be manual or Mayor-driven |

---

## 2. Philosophical Differences

### 2.1 Intelligence vs Determinism

**Gastown**: Hybrid approach. Uses "The Mayor" (AI coordinator) for high-level decisions, but has deterministic components (formulas, GUPP principle, structured bead IDs).

**AI DevOps**: Explicitly favors intelligence over determinism. "The harness gives you goals, tools, and boundaries — not scripts for every scenario." No state machines, no SQLite for orchestration state.

**Takeaway**: Gastown's structured approach to orchestration (formulas, health states) could inform aidevops without violating the intelligence principle. The "Problems View" pattern is particularly valuable.

### 2.2 State Management

**Gastown**: Uses Dolt (Git for data) for structured state. Beads are atomic work units with IDs like `gt-abc12`.

**AI DevOps**: Uses GitHub Issues + TODO.md as the "only state DB." "Never duplicate this state into separate files, databases, or logs."

**Takeaway**: aidevops' approach is simpler but may lack granularity for tracking sub-task state. Gastown's bead/convoy model could inspire better task bundling.

### 2.3 Multi-Runtime Support

**Gastown**: First-class support for Claude, Codex, Cursor, Gemini, OpenCode, Copilot with presets in `config.json`.

**AI DevOps**: Claude Code is primary; others supported as "courtesy." Uses `opencode run` exclusively for dispatch.

**Takeaway**: Gastown's agnostic approach to runtimes is more robust. aidevops' Claude-first approach is pragmatic but may limit portability.

---

## 3. Specific Improvement Opportunities for AI DevOps

### 3.1 High-Impact Additions

#### 1. Activity Feed TUI (`/feed`)

**Gastown feature**: `gt feed` — interactive terminal dashboard with:
- Agent Tree (hierarchical view by rig/role)
- Convoy Panel (in-progress work)
- Event Stream (chronological feed)

**aidevops current**: `/dashboard` generates static HTML; `mission-dashboard-helper.sh` outputs formatted text.

**Recommendation**: Create a real-time TUI dashboard using a library like `tview` (Go) or `rich` (Python) or even a simple `fzf`-like interface. It would:
- Show active workers with PIDs and elapsed time
- Display PR status with CI checks
- Show TODO queue with priorities
- Auto-refresh every 10-30 seconds

**Implementation**: New command `/feed` that launches a TUI dashboard. Could be a small Go binary or a Python script using `rich`/`textual`.

#### 2. Problems View / Health States

**Gastown feature**: Structured health states for agents:
- **GUPP Violation**: Hooked work with no progress for extended period
- **Stalled**: Hooked work with reduced progress
- **Zombie**: Dead tmux session
- **Working**: Active, progressing normally
- **Idle**: No hooked work

**aidevops current**: Pulse detects stuck workers (>3h with no PR) and kills them. Less structured.

**Recommendation**: Formalize health states in issue labels or TODO.md:
- `health:stalled` — worker running but no commits for 1h
- `health:zombie` — worker process disappeared but issue still open
- `health:overdue` — PR open but CI failing for 24h+
- `health:orphaned` — PR abandoned

**Implementation**: Enhance pulse to set health labels, not just status labels. Add `problems-helper.sh` to surface issues needing attention.

#### 3. Formula Workflows

**Gastown feature**: TOML-defined formulas in `internal/formula/formulas/`:

```toml
description = "Standard release process"
formula = "release"
version = 1

[[steps]]
id = "bump-version"
title = "Bump version"
description = "Run ./scripts/bump-version.sh {{version}}"

[[steps]]
id = "run-tests"
title = "Run tests"
description = "Run make test"
needs = ["bump-version"]
```

**aidevops current**: No formal workflow templates. Release process is documented in `release.md` but not executable.

**Recommendation**: Create formula system for common workflows:
- Release (bump version → test → build → tag → publish)
- Dependency update (check → update → test → PR)
- Security patch (assess → patch → test → release)

**Implementation**: New `todo/formulas/` directory with TOML definitions. New command `/formula run <name>` that executes steps with dependency resolution.

#### 4. Convoy Work Bundling

**Gastown feature**: Convoys group related beads/issues. `gt convoy create "Feature X" gt-abc12 gt-def34`.

**aidevops current**: Task decomposition (t1408) splits tasks into subtasks but doesn't bundle existing issues.

**Recommendation**: Add convoy concept to TODO.md:

```markdown
- [ ] cv001 Feature: OAuth Integration ~3d #auth
  - [ ] t101 Add login endpoint
  - [ ] t102 Add token refresh
  - [ ] t103 Add logout
```

Convoy ID `cv001` groups related tasks. Commands: `/convoy create`, `/convoy list`, `/convoy show`.

#### 5. Enhanced Web Dashboard

**Gastown feature**: `gt dashboard` with:
- Auto-refresh via htmx
- Command palette for running gt commands from browser
- Single-page overview

**aidevops current**: `/dashboard browser` generates static HTML, no auto-refresh.

**Recommendation**: Enhance dashboard with:
- htmx auto-refresh (every 30s)
- Command palette for common operations
- Real-time worker status via simple polling API

**Implementation**: Add htmx CDN to generated HTML. Create simple HTTP endpoint (could be a Python one-liner) for status queries.

---

### 3.2 Medium-Impact Additions

#### 6. Formalized Mailbox/Messaging

**Gastown feature**: `gt nudge` for real-time messaging between agents; mail system for async communication.

**aidevops current**: Cross-session memory (`/remember`, `/recall`) but no formal message passing.

**Recommendation**: Add mailbox system using existing file structure:
- `~/.aidevops/.agent-workspace/mail/inbox/`
- `~/.aidevops/.agent-workspace/mail/outbox/`
- `~/.aidevops/.agent-workspace/mail/archive/`

Command: `/mail send <agent> <message>`, `/mail check`

#### 7. GUPP Principle Formalization

**Gastown feature**: GUPP (Gas Town Universal Propulsion Principle): "If there is work on your Hook, YOU MUST RUN IT."

**aidevops current**: Implicit in `/full-loop` but not documented as principle.

**Recommendation**: Add explicit principle to `/full-loop` documentation. Consider adding hook-check step: before starting new work, check if any previous work on this branch/worktree needs attention.

#### 8. Runtime-Agnostic Dispatch

**Gastown feature**: Built-in presets for Claude, Codex, Cursor, Gemini, OpenCode, Copilot.

**aidevops current**: Claude Code primary; `opencode run` for dispatch.

**Recommendation**: Add runtime configuration in repos.json:

```json
{
  "runtime": {
    "provider": "claude",
    "command": "claude",
    "args": ["--resume"]
  }
}
```

Fallback chain if primary runtime unavailable.

#### 9. Tmux Session Management

**Gastown feature**: Full tmux integration for session persistence.

**aidevops current**: No tmux integration.

**Recommendation**: Optional tmux integration for workers:
- `gt session attach` to attach to worker session
- Auto-reconnect on crash
- Session survival across machine restarts

#### 10. Dolt/Beads-style Structured State

**Gastown feature**: Dolt (Git for data) for structured work units.

**aidevops current**: JSONL files, SQLite for memory.

**Recommendation**: Consider Dolt or similar for complex state:
- Task dependencies
- Worker history
- Pattern tracking

**Caution**: This conflicts with "intelligence over determinism" and "GitHub is the state DB." Only use if SQLite proves insufficient.

---

## 4. Architecture Lessons

### 4.1 What Gastown Does Well

1. **Conceptual clarity**: Mayor, Polecats, Convoys, Hooks — each has clear responsibilities
2. **TUI experience**: Activity feed is genuinely useful for monitoring
3. **Health state machine**: Structured states enable better automation
4. **Formulas**: Reusable workflows reduce setup friction
5. **Multi-runtime**: Not locked into one AI coding tool
6. **Web dashboard**: htmx auto-refresh is simple but effective

### 4.2 What AI DevOps Does Well

1. **Quality gates**: ShellCheck, linting on every edit is a major differentiator
2. **Cost awareness**: Model routing and budget tracking are production-grade
3. **No state duplication**: GitHub is the DB eliminates sync issues
4. **Pre-edit protection**: Prevents main-branch edits
5. **Skill system**: 25+ integrated services with standardized patterns
6. **Traceability**: Every change discoverable via git

### 4.3 What Not to Copy

1. **Compiled binary**: Gastown's Go binary requires build/deployment; aidevops shell scripts are more hackable
2. **Beads/Dolt dependency**: Adds complexity; GitHub Issues + TODO.md is sufficient
3. **Tmux requirement**: Adds friction; modern tools like `opencode` handle session management
4. **Structured bead IDs**: `gt-abc12` format requires central allocation; aidevops' `claim-task-id.sh` with CAS is simpler

---

## 5. Recommended Priorities

### Phase 1: Quick Wins (1-2 weeks)

1. **Activity Feed TUI** — `/feed` command with real-time worker status
2. **Health State Labels** — Enhance pulse to set `health:*` labels
3. **Formula System** — TOML workflows for release, dependency updates
4. **GUPP Principle Documentation** — Add to `/full-loop` docs

### Phase 2: Medium Effort (1-2 months)

5. **Convoy Work Bundling** — Group related tasks in TODO.md
6. **Enhanced Web Dashboard** — htmx auto-refresh, command palette
7. **Problems View** — `problems-helper.sh` to surface issues needing attention
8. **Mailbox System** — Formalize inter-agent messaging

### Phase 3: Longer Term (2-3 months)

9. **Multi-runtime Configuration** — Runtime presets in repos.json
10. **Structured State Exploration** — Evaluate Dolt for complex dependencies (if needed)

---

## 6. Conclusion

Gastown and AI DevOps share similar goals but different philosophies. Gastown provides structure (formulas, health states, TUI); aidevops provides intelligence (no state machines, GitHub as DB).

**The best improvements for aidevops would incorporate gastown's clarity and user experience without compromising its core intelligence-over-determinism philosophy.**

Key takeaways:
1. Activity Feed TUI would significantly improve observability
2. Health state machine would make stuck-agent detection more robust
3. Formulas would reduce friction for common workflows
4. Convoy bundling would improve multi-issue coordination

**Next step**: Create issues for Phase 1 quick wins, starting with Activity Feed TUI and Formula System.
