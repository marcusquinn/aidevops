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

# Recall memories
~/.aidevops/agents/scripts/memory-helper.sh recall "cors"

# Show recent memories
~/.aidevops/agents/scripts/memory-helper.sh recall --recent

# View statistics
~/.aidevops/agents/scripts/memory-helper.sh stats
```

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Store a memory with AI-assisted categorization |
| `/recall {query}` | Search memories by keyword |
| `/recall --recent` | Show 10 most recent memories |
| `/recall --stats` | Show memory statistics |

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

## Storage Location

```text
~/.aidevops/.agent-workspace/memory/
├── memory.db           # SQLite database with FTS5
├── embeddings.db       # Optional: vector embeddings for semantic search
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
memory-helper.sh validate          # Check for stale entries
memory-helper.sh prune --dry-run   # Preview cleanup
memory-helper.sh prune             # Remove stale entries

# Export
memory-helper.sh export --format json   # Export as JSON
memory-helper.sh export --format toon   # Export as TOON (token-efficient)
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
- **Keep sensitive data** in separate secure locations (`~/.config/aidevops/mcp-env.sh`)
- **Regular cleanup** of outdated information
- **No personal identifiable information** in shareable templates

## Important Reminders

- **Never store personal data** in this template directory
- **Use ~/.aidevops/.agent-workspace/memory/** for all actual operations
- **This directory is version controlled** - keep it clean
- **Respect privacy** - be mindful of what you store
- **Update preferences** when developer feedback indicates a change
