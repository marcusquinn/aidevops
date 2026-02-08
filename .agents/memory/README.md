---
description: Memory template directory documentation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Memory System

Cross-session memory for AI assistants using SQLite FTS5 for fast full-text search.

**Requires**: `sqlite3` CLI (includes FTS5 by default)

```bash
# Ubuntu/Debian
sudo apt install sqlite3

# macOS (usually pre-installed)
brew install sqlite3

# Verify installation
sqlite3 --version
```

**Motto**: "Compound, then clear" - Sessions should build on each other.

**Inspired by**: [Supermemory](https://supermemory.ai/research) architecture for:

- **Relational versioning** - Track how memories evolve (updates, extends, derives)
- **Dual timestamps** - Distinguish when stored vs when event occurred
- **Contextual disambiguation** - Self-contained, atomic memories

## Quick Start

```bash
# Store a memory
~/.aidevops/agents/scripts/memory-helper.sh store --type "WORKING_SOLUTION" --content "Fixed CORS with nginx headers" --tags "cors,nginx"

# Store with event date (when it happened, not when stored)
~/.aidevops/agents/scripts/memory-helper.sh store --content "Deployed v2.0" --event-date "2024-01-15T10:00:00Z"

# Update an existing memory (creates version chain)
~/.aidevops/agents/scripts/memory-helper.sh store --content "Favorite color is now green" --supersedes mem_xxx --relation updates

# View version history
~/.aidevops/agents/scripts/memory-helper.sh history mem_xxx

# Store an auto-captured memory (from AI agent)
~/.aidevops/agents/scripts/memory-helper.sh store --auto --type "WORKING_SOLUTION" --content "Fixed CORS with nginx headers" --tags "cors,nginx"

# Recall memories
~/.aidevops/agents/scripts/memory-helper.sh recall "cors"

# Show recent memories
~/.aidevops/agents/scripts/memory-helper.sh recall --recent

# Show auto-capture log
~/.aidevops/agents/scripts/memory-helper.sh log

# View statistics (includes auto-capture counts)
~/.aidevops/agents/scripts/memory-helper.sh stats

# Remove duplicate memories
~/.aidevops/agents/scripts/memory-helper.sh dedup --dry-run
~/.aidevops/agents/scripts/memory-helper.sh dedup

# Validate memory health (staleness, duplicates, size)
~/.aidevops/agents/scripts/memory-helper.sh validate
```

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Store a memory with AI-assisted categorization |
| `/recall {query}` | Search memories by keyword |
| `/recall --recent` | Show 10 most recent memories |
| `/recall --auto-only` | Search only auto-captured memories |
| `/recall --stats` | Show memory statistics |
| `/memory-log` | Show recent auto-captured memories |

See `scripts/commands/remember.md` and `scripts/commands/recall.md` for full documentation.

## Memory Types

| Type | Use For |
|------|---------|
| `WORKING_SOLUTION` | Fixes that worked |
| `FAILED_APPROACH` | What didn't work (avoid repeating) |
| `CODEBASE_PATTERN` | Project conventions |
| `USER_PREFERENCE` | Developer preferences |
| `TOOL_CONFIG` | Tool setup notes |
| `DECISION` | Architecture decisions |
| `CONTEXT` | Background info |
| `SUCCESS_PATTERN` | Approaches that consistently work for task types |
| `FAILURE_PATTERN` | Approaches that consistently fail for task types |

## Auto-Capture

AI agents automatically store memories using the `--auto` flag when they detect
significant events (working solutions, failed approaches, decisions). This is
tool-agnostic - works with Claude Code, OpenCode, Cursor, Windsurf, or any AI
tool that reads AGENTS.md.

**How it works:**

1. Agent detects a trigger (e.g., solution found, preference stated)
2. Agent stores with `--auto` flag: `memory-helper.sh store --auto --content "..."`
3. Auto-captured memories are tracked separately from manual `/remember` entries
4. Review with `/memory-log` or `memory-helper.sh log`

**Privacy filters (applied automatically on store):**

- `<private>...</private>` blocks are stripped from content
- Content matching secret patterns (API keys, tokens) is rejected
- Credentials and sensitive config values are never stored

**Filtering:**

```bash
# Show only auto-captured memories
memory-helper.sh recall "query" --auto-only

# Show only manually stored memories
memory-helper.sh recall "query" --manual-only

# Show auto-capture log (recent auto-captures)
memory-helper.sh log
memory-helper.sh log --limit 50
```

## Relation Types

Inspired by Supermemory's relational versioning:

| Relation | Use For | Example |
|----------|---------|---------|
| `updates` | New info supersedes old (state mutation) | "Favorite color is now green" updates "...is blue" |
| `extends` | Adds detail without contradiction | Adding job title to existing employment memory |
| `derives` | Second-order inference from combining | Inferring "works remotely" from location + job info |

## Dual Timestamps

| Timestamp | Purpose |
|-----------|---------|
| `created_at` | When the memory was stored in the database |
| `event_date` | When the event described actually occurred |

This enables temporal reasoning like "what happened last week?" by distinguishing
between when you learned something vs when it happened.

## Deduplication

The memory system prevents duplicate entries at two levels:

**On store (automatic):** Before inserting a new memory, the system checks for:

- **Exact duplicates**: identical content string with the same type
- **Near-duplicates**: same content after normalizing case, punctuation, and whitespace

When a duplicate is detected, the existing entry's access count is incremented and its ID is returned. No new entry is created.

**Bulk deduplication:** For cleaning up existing duplicates:

```bash
# Preview what would be removed
memory-helper.sh dedup --dry-run

# Remove all duplicates (keeps oldest, merges tags)
memory-helper.sh dedup

# Only remove exact duplicates (skip near-duplicates)
memory-helper.sh dedup --exact-only
```

## Auto-Pruning

Stale entries are automatically pruned to keep the memory database lean:

- **Trigger**: Runs opportunistically on every `store` call (at most once per 24 hours)
- **Criteria**: Removes entries older than 90 days that have never been accessed
- **Safe**: Frequently accessed memories are preserved regardless of age
- **Manual override**: Use `prune` command for custom thresholds

```bash
# Manual prune with custom threshold
memory-helper.sh prune --older-than-days 60

# Preview before pruning
memory-helper.sh prune --older-than-days 60 --dry-run

# Also prune accessed entries (use with caution)
memory-helper.sh prune --older-than-days 180 --include-accessed
```

## Semantic Search (Opt-in)

For similarity-based search beyond keyword matching, enable vector embeddings:

```bash
# One-time setup (~90MB model download)
memory-embeddings-helper.sh setup

# Index existing memories
memory-embeddings-helper.sh index

# Search by meaning (not just keywords)
memory-helper.sh recall "how to optimize database queries" --semantic

# Or use the embeddings helper directly
memory-embeddings-helper.sh search "authentication patterns"
```

FTS5 keyword search remains the default. Semantic search requires Python 3.9+ and sentence-transformers.

## Pattern Tracking

Track what works and what fails across task types and models:

```bash
# Record a pattern
pattern-tracker-helper.sh record --outcome success --task-type bugfix \
    --model sonnet --description "Structured debugging found root cause"

# Get suggestions for a task
pattern-tracker-helper.sh suggest "refactor the auth middleware"

# View pattern statistics
pattern-tracker-helper.sh stats

# Or use the /patterns command
/patterns refactor
```

See `scripts/pattern-tracker-helper.sh` for full documentation.

## Namespaces (Per-Runner Memory Isolation)

Runners can have isolated memory namespaces. Each namespace gets its own SQLite DB,
preventing cross-contamination between parallel agents while allowing shared access
to global memories when needed.

```bash
# Store in a runner-specific namespace
memory-helper.sh --namespace code-reviewer store --content "Prefer explicit error handling"

# Recall from namespace only
memory-helper.sh --namespace code-reviewer recall "error handling"

# Recall from namespace + global (shared access)
memory-helper.sh --namespace code-reviewer recall "error handling" --shared

# View namespace stats
memory-helper.sh --namespace code-reviewer stats

# List all namespaces
memory-helper.sh namespaces
```

Namespace DBs are stored at `memory/namespaces/<name>/memory.db`. The global DB
remains at `memory/memory.db` and is always accessible without `--namespace`.

## Storage Location

```text
~/.aidevops/.agent-workspace/memory/
├── memory.db           # Global SQLite database with FTS5
├── embeddings.db       # Optional: vector embeddings for semantic search
├── namespaces/         # Per-runner isolated memory
│   ├── code-reviewer/
│   │   └── memory.db
│   └── seo-analyst/
│       └── memory.db
└── preferences/        # Optional: markdown preference files
```

## CLI Reference

```bash
# Store with project context
memory-helper.sh store --type "TYPE" --content "content" --tags "tags" --project "project-name"

# Store with event date (when it happened)
memory-helper.sh store --content "Fixed bug" --event-date "2024-01-15T10:00:00Z"

# Update an existing memory (relational versioning)
memory-helper.sh store --content "New info" --supersedes mem_xxx --relation updates

# Extend a memory with more detail
memory-helper.sh store --content "Additional context" --supersedes mem_xxx --relation extends

# Search with filters
memory-helper.sh recall "query" --type WORKING_SOLUTION --project myapp --limit 20

# Show recent memories
memory-helper.sh recall --recent 10

# Version history
memory-helper.sh history mem_xxx   # Show ancestors and descendants
memory-helper.sh latest mem_xxx    # Find latest version in chain

# Maintenance
memory-helper.sh validate          # Check for stale entries and duplicates
memory-helper.sh dedup --dry-run   # Preview duplicate removal
memory-helper.sh dedup             # Remove duplicate entries
memory-helper.sh prune --dry-run   # Preview stale entry cleanup
memory-helper.sh prune             # Remove stale entries

# Export
memory-helper.sh export --format json   # Export as JSON
memory-helper.sh export --format toon   # Export as TOON (token-efficient)

# Namespaces (per-runner isolation)
memory-helper.sh --namespace my-runner store --content "Runner-specific learning"
memory-helper.sh --namespace my-runner recall "query" --shared  # Also search global
memory-helper.sh namespaces            # List all namespaces
```

## Legacy: File-Based Preferences

For detailed preference files (optional, complements SQLite):

```text
~/.aidevops/.agent-workspace/memory/preferences/
├── coding-style.md
├── workflow.md
└── project-specific/
    └── wordpress.md
```

## Developer Preferences Memory

### Purpose

Maintain a consistent record of developer preferences across coding sessions to:

- Ensure AI assistants provide assistance aligned with the developer's preferred style
- Reduce the need for developers to repeatedly explain their preferences
- Create a persistent context across tools and sessions

### How AI Assistants Should Use Preferences

1. **Before starting work**: Check `~/.aidevops/.agent-workspace/memory/preferences/` for relevant preferences
2. **During development**: Apply established preferences to suggestions and code
3. **When feedback is given**: Update preference files to record new preferences
4. **When switching projects**: Check for project-specific preference files

### Preference Categories to Track

#### Code Style Preferences

```markdown
# ~/.aidevops/.agent-workspace/memory/preferences/coding-style.md

## General
- Preferred indentation: [tabs/spaces, count]
- Line length limit: [80/100/120]
- Quote style: [single/double]

## Language-Specific
### JavaScript/TypeScript
- Semicolons: [yes/no]
- Arrow functions: [preferred/when-appropriate]

### Python
- Type hints: [always/public-only/never]
- Docstring style: [Google/NumPy/Sphinx]

### PHP
- WordPress coding standards: [yes/no]
- PSR-12: [yes/no]
```

#### Documentation Preferences

```markdown
# ~/.aidevops/.agent-workspace/memory/preferences/documentation.md

## Code Comments
- Prefer: [minimal/moderate/extensive]
- JSDoc/PHPDoc: [always/public-only/never]

## Project Documentation
- README format: [brief/comprehensive]
- Changelog style: [Keep a Changelog/custom]

## AI Assistant Documentation
- Token-efficient: [yes/no]
- Reference external files: [yes/no]
```

#### Workflow Preferences

```markdown
# ~/.aidevops/.agent-workspace/memory/preferences/workflow.md

## Git
- Commit message style: [conventional/descriptive]
- Branch naming: [feature/issue-123/kebab-case]
- Squash commits: [yes/no]

## Testing
- Test coverage minimum: [80%/90%/100%]
- TDD approach: [yes/no]

## CI/CD
- Auto-fix on commit: [yes/no]
- Required checks: [list]
```

#### Tool Preferences

```markdown
# ~/.aidevops/.agent-workspace/memory/preferences/tools.md

## Editors/IDEs
- Primary: [VS Code/Cursor/etc]
- Extensions: [list relevant]

## Terminal
- Shell: [zsh/bash/fish]
- Custom aliases: [note any that affect commands]

## Environment
- Node.js manager: [nvm/n/fnm]
- Python manager: [pyenv/conda/system]
- Package managers: [npm/yarn/pnpm]
```

### Project-Specific Preferences

For projects with unique requirements:

```markdown
# ~/.aidevops/.agent-workspace/memory/preferences/project-specific/wordpress.md

## WordPress Development
- Prefer simpler solutions over complex ones
- Follow WordPress coding standards
- Use OOP best practices
- Admin functionality in admin/lib/
- Core functionality in includes/
- Assets in /assets organized by admin folders
- Version updates require language file updates (POT/PO)

## Plugin Release Process
- Create version branch from main
- Update all version references
- Run quality checks before merge
- Create GitHub tag and release
- Ensure readme.txt is updated (Git Updater uses main branch)
```

### Potential Issues to Track

Document environment-specific issues that affect AI assistance:

```markdown
# ~/.aidevops/.agent-workspace/memory/preferences/environment-issues.md

## Terminal Customizations
- Non-standard prompt: [describe]
- Custom aliases that might confuse: [list]
- Shell integrations: [starship/oh-my-zsh/etc]

## Multiple Runtime Versions
- Node.js versions: [list, note if Homebrew]
- Python versions: [list, note manager]
- PHP versions: [list]

## Known Conflicts
- [Document any tool conflicts discovered]
```

## Security Guidelines

- **Never store credentials** in memory files
- **Use configuration references** instead of actual API keys
- **Keep sensitive data** in separate secure locations (`~/.config/aidevops/credentials.sh`)
- **Regular cleanup** of outdated information
- **No personal identifiable information** in shareable templates

## Important Reminders

- **Never store personal data** in this template directory
- **Use ~/.aidevops/.agent-workspace/memory/** for all actual operations
- **This directory is version controlled** - keep it clean
- **Respect privacy** - be mindful of what you store
- **Update preferences** when developer feedback indicates a change
