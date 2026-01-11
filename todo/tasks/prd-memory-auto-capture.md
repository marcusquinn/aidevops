---
mode: subagent
---
# Product Requirements Document: Memory Auto-Capture

Based on [ai-dev-tasks](https://github.com/snarktank/ai-dev-tasks) PRD format, with time tracking.

<!--TOON:prd{id,feature,author,status,est,est_ai,est_test,est_read,logged}:
prd-memory-auto-capture,Memory Auto-Capture,aidevops,draft,1d,6h,4h,2h,2026-01-11T12:00Z
-->

## Overview

**Feature:** Memory Auto-Capture
**Author:** aidevops
**Date:** 2026-01-11
**Status:** Draft
**Estimate:** ~1d (ai:6h test:4h read:2h)
**Reference:** [claude-mem](https://github.com/thedotmack/claude-mem) - 13k+ stars, inspiration for auto-capture patterns

### Problem Statement

Currently, aidevops memory requires manual `/remember` invocation. Users must consciously decide what to store, leading to:
- Forgotten solutions that worked
- Repeated debugging of the same issues
- Lost context between sessions
- Inconsistent memory capture across users

claude-mem solves this with automatic capture via lifecycle hooks, but is Claude Code-only. aidevops needs a tool-agnostic solution.

### Goal

Implement automatic memory capture that:
1. Works across all AI tools (OpenCode, Cursor, Claude Code, Windsurf)
2. Captures working solutions, failed approaches, and decisions automatically
3. Uses progressive disclosure to minimize token usage
4. Maintains our minimal dependency philosophy (bash + sqlite3)

## User Stories

### Primary User Story

As a developer using AI assistants, I want my working solutions and failed approaches automatically captured so that future sessions can learn from past work without manual intervention.

### Additional User Stories

- As a developer, I want to see what was auto-captured so I can verify quality and prune noise.
- As a developer, I want to control what gets captured so sensitive information stays private.
- As a developer, I want auto-captured memories to be searchable so I can find relevant context quickly.

## Functional Requirements

### Core Requirements

1. **Post-Tool Capture Hook**: Automatically capture observations after significant tool operations (file edits, bash commands, git operations)
2. **Semantic Classification**: Auto-classify captures into memory types (WORKING_SOLUTION, FAILED_APPROACH, CODEBASE_PATTERN, etc.)
3. **Deduplication**: Prevent storing duplicate or near-duplicate observations
4. **Privacy Controls**: Support `<private>` tags or patterns to exclude sensitive content

### Secondary Requirements

5. **Capture Summary View**: `/memory-log` command to show recent auto-captures
6. **Capture Pruning**: Automatic cleanup of low-value captures after N days
7. **Progressive Disclosure**: Index-first retrieval pattern (like claude-mem's 3-layer workflow)

## Non-Goals (Out of Scope)

- Vector embeddings / semantic search (keep FTS5 for simplicity)
- Web UI for memory browsing (CLI-only for now)
- AI-powered compression of observations (store raw, let retrieval filter)
- Real-time sync across machines (local SQLite only)
- Claude Code plugin architecture (we're tool-agnostic)

## Design Considerations

### Capture Triggers

| Trigger | What to Capture | Memory Type |
|---------|-----------------|-------------|
| File edit succeeds | File path, change summary | CODEBASE_PATTERN |
| Bash command succeeds | Command, output summary | WORKING_SOLUTION |
| Bash command fails | Command, error message | FAILED_APPROACH |
| Git commit | Commit message, files changed | DECISION |
| Error resolved | Error message, fix applied | WORKING_SOLUTION |

### Capture Format

```json
{
  "timestamp": "2026-01-11T12:00:00Z",
  "type": "WORKING_SOLUTION",
  "trigger": "bash_success",
  "content": "Fixed CORS with nginx: add_header 'Access-Control-Allow-Origin' '*';",
  "context": {
    "project": "myapp",
    "file": "nginx.conf",
    "command": "nginx -t && nginx -s reload"
  },
  "auto_captured": true
}
```

### User Experience

1. **Transparent**: Auto-capture happens silently, no interruption
2. **Reviewable**: `/memory-log` shows what was captured
3. **Controllable**: `<private>` tags exclude content
4. **Searchable**: `/recall` finds both manual and auto-captured memories

## Technical Considerations

### Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                     AI Assistant Session                     │
├─────────────────────────────────────────────────────────────┤
│  Tool Call (Edit/Bash/Git)                                  │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────────┐                                        │
│  │ Capture Filter  │ ← Checks: success? significant? private?│
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │ Auto-Classifier │ ← Determines memory type               │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │ Deduplicator    │ ← FTS5 similarity check                │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │ memory-helper.sh│ ← store --auto-captured                │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │   memory.db     │ ← SQLite FTS5                          │
│  └─────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

### Implementation Options

**Option A: Agent Instructions (Recommended)**
- Add auto-capture instructions to AGENTS.md
- AI assistant calls `memory-helper.sh store --auto` after significant operations
- Works with any AI tool that reads AGENTS.md
- No external dependencies

**Option B: Shell Wrapper**
- Wrap common commands (git, npm, etc.) with capture hooks
- More automatic but requires shell configuration
- May conflict with user's existing aliases

**Option C: File Watcher**
- Watch for file changes and git operations
- Most automatic but requires background daemon
- Adds complexity, may miss context

**Recommendation:** Option A - Agent instructions are tool-agnostic and require no additional infrastructure.

### Dependencies

- `memory-helper.sh`: Existing script, needs `--auto-captured` flag
- `sqlite3`: Already required for memory system
- No new dependencies

### Constraints

- Must work without background processes
- Must not slow down normal operations
- Must respect `.gitignore` patterns for privacy
- Must work offline (no API calls for classification)

### Security Considerations

- Never auto-capture content matching `.gitignore` patterns
- Never auto-capture content in `<private>` tags
- Never auto-capture credentials, API keys, or secrets
- Respect `secretlint` patterns for exclusion

## Time Estimate Breakdown

| Phase | AI Time | Test Time | Read Time | Total |
|-------|---------|-----------|-----------|-------|
| Research & Design | 1h | - | 1h | 2h |
| memory-helper.sh updates | 2h | 1h | 30m | 3.5h |
| AGENTS.md instructions | 1h | 30m | 30m | 2h |
| /memory-log command | 1h | 1h | - | 2h |
| Privacy filters | 1h | 1.5h | - | 2.5h |
| **Total** | **6h** | **4h** | **2h** | **12h** |

<!--TOON:time_breakdown[5]{phase,ai,test,read,total}:
research,1h,,1h,2h
memory-helper,2h,1h,30m,3.5h
agents-md,1h,30m,30m,2h
memory-log,1h,1h,,2h
privacy,1h,1.5h,,2.5h
-->

## Success Metrics

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Auto-captures per session | 5-20 | Count in memory.db |
| Duplicate rate | <10% | Dedup filter stats |
| Retrieval relevance | >80% useful | User feedback |
| Performance impact | <100ms per capture | Timing logs |

## Open Questions

- [x] Should we use agent instructions or shell wrappers? → Agent instructions (Option A)
- [ ] What's the right threshold for "significant" operations?
- [ ] Should auto-captures have lower priority in search results?
- [ ] How long to retain auto-captures before pruning?

## Appendix

### Related Documents

- [memory/README.md](../../.agent/memory/README.md) - Current memory system docs
- [claude-mem](https://github.com/thedotmack/claude-mem) - Reference implementation
- [scripts/commands/remember.md](../../.agent/scripts/commands/remember.md) - Manual memory command

### Comparison with claude-mem

| Feature | claude-mem | aidevops (proposed) |
|---------|------------|---------------------|
| Auto-capture | Lifecycle hooks | Agent instructions |
| Storage | SQLite + Chroma | SQLite FTS5 only |
| Search | Semantic + keyword | FTS5 keyword |
| Dependencies | Bun, uv, Chroma | bash, sqlite3 |
| Tool support | Claude Code only | All AI tools |
| Token efficiency | 3-layer progressive | Index-first retrieval |

### Revision History

| Date | Author | Changes |
|------|--------|---------|
| 2026-01-11 | aidevops | Initial draft |
