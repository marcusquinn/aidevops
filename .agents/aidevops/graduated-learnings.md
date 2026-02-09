---
description: Shared learnings graduated from local memory across all users
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
---

# Graduated Learnings

Validated learnings promoted from local memory databases into shared documentation.
These patterns have been confirmed through repeated use across sessions.

**How memories graduate**: Memories qualify when they reach high confidence or are
accessed frequently (3+ times). The `memory-graduate-helper.sh` script identifies
candidates and appends them here. Each graduation batch is timestamped.

**Categories**:

- **Solutions & Fixes**: Working solutions to real problems
- **Anti-Patterns**: Approaches that failed (avoid repeating)
- **Patterns & Best Practices**: Proven approaches
- **Architecture Decisions**: Key design choices and rationale
- **Configuration & Preferences**: Tool and workflow settings
- **Context & Background**: Important background information

**Usage**: `memory-helper.sh graduate [candidates|graduate|status]`

## Graduated: 2026-02-08

### Anti-Patterns (What NOT to Do)

- **[FAILED_APPROACH]** Tried using PostgreSQL for memory but it adds deployment complexity - SQLite FTS5 is simpler
  *(confidence: high, validated: 9x)*

- **[FAILURE_PATTERN]** [task:refactor] Haiku missed edge cases when refactoring complex shell scripts with many conditionals [model:haiku]
  *(confidence: high, validated: 3x)*

### Architecture Decisions

- **[ARCHITECTURAL_DECISION]** YAML handoffs are more token-efficient than markdown (~400 vs ~2000 tokens)
  *(confidence: high, validated: 0x)*

- **[DECISION]** Mailbox uses SQLite (mailbox.db) not TOON files. Prune shows storage report by default, --force to delete. Migration from TOON runs automatically on aidevops update via setup.sh.
  *(confidence: medium, validated: 8x)*

- **[DECISION]** Agent lifecycle uses three tiers: draft/ (R&D, orchestration-created), custom/ (private, permanent), shared (.agents/ via PR). Both draft/ and custom/ survive setup.sh deployments. Orchestration agents (Build+, Ralph loop, runners) know they can create drafts for reusable parallel processing context and propose them for inclusion in aidevops.
  *(confidence: medium, validated: 3x)*

### Configuration & Preferences

- **[USER_PREFERENCE]** Prefer conventional commits with scope: feat(memory): description
  *(confidence: medium, validated: 4x)*

### Patterns & Best Practices

- **[SUCCESS_PATTERN]** [task:feature] Breaking task into 4 phases with separate commits worked well for Claude-Flow feature adoption [model:sonnet]
  *(confidence: high, validated: 3x)*

- **[SUCCESS_PATTERN]** [task:bugfix] Opus identified root cause of race condition by reasoning through concurrent execution paths [model:opus]
  *(confidence: high, validated: 2x)*

- **[CODEBASE_PATTERN]** Memory daemon should auto-extract learnings from thinking blocks when sessions end
  *(confidence: medium, validated: 5x)*
