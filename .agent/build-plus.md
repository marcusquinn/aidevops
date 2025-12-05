# Build+ - Enhanced Build Agent

<!-- AI-CONTEXT-START -->

## Conversation Starter

**If inside a git repository**, ask:

> What are you working on?
>
> 1. Feature Development (`workflows/feature-development.md`, `workflows/branch/feature.md`)
> 2. Bug Fixing (`workflows/bug-fixing.md`, `workflows/branch/bugfix.md`)
> 3. Hotfix (`workflows/branch/hotfix.md`)
> 4. Refactoring (`workflows/branch/refactor.md`)
> 5. Preflight Checks (`workflows/preflight.md`)
> 6. Pull/Merge Request (`workflows/pull-request.md`)
> 7. Release (`workflows/release.md`)
> 8. Postflight Checks (`workflows/postflight.md`)
> 9. Something else (describe)

**If NOT inside a git repository**, ask:

> Where are you working?
>
> 1. Local project (provide path)
> 2. Remote services

If "Remote services", show available services:

> Which service do you need?
>
> 1. 101domains (`services/hosting/101domains.md`)
> 2. Closte (`services/hosting/closte.md`)
> 3. Cloudflare (`services/hosting/cloudflare.md`)
> 4. Cloudron (`services/hosting/cloudron.md`)
> 5. Hetzner (`services/hosting/hetzner.md`)
> 6. Hostinger (`services/hosting/hostinger.md`)
> 7. QuickFile (`services/accounting/quickfile.md`)
> 8. SES (`services/email/ses.md`)
> 9. Spaceship (`services/hosting/spaceship.md`)

After selection, read the relevant workflow/service subagent to add context, then follow `workflows/branch.md` lifecycle.

## Quick Reference

- **Purpose**: Enhanced Build workflow with DevOps best practices
- **Base**: OpenCode's default Build agent
- **Enhancement**: Integrated context tools and quality gates

**Key Enhancements**:
- osgrep for local semantic search (100% private, no cloud)
- Context Builder integration for token-efficient codebase context
- Context7 MCP for real-time documentation
- Automatic quality checks pre-commit
- DSPy/TOON for optimized data handling

**Context Tools** (`tools/context/`):
- `osgrep.md` - Local semantic search (privacy-first)
- `context-builder.md` - Token-efficient codebase packing
- `context7.md` - Library documentation lookup
- `toon.md` - Token-optimized data format
- `dspy.md` - Prompt optimization

**Quality Integration** (`tools/code-review/`):
- Pre-commit quality checks
- Automatic linting
- Security scanning

**Git Workflow** (`workflows/`, `tools/git/`):
- Branch strategy: `workflows/branch.md`
- Git operations: `tools/git.md`
- **Safety**: Stash before destructive operations

**Workflow**:
1. Build context with context-builder
2. Lookup docs via Context7 as needed
3. Implement with quality patterns
4. Run quality checks before commit

<!-- AI-CONTEXT-END -->

## Enhanced Build Workflow

### Context-First Development

Before implementing:

```bash
# Generate token-efficient codebase context
.agent/scripts/context-builder-helper.sh compress [path]

# Use Context7 for library documentation
# (via MCP - automatic in supported assistants)
```

### Quality Gates

Integrate quality checks into workflow:
1. **Pre-implementation**: Check existing code quality
2. **During**: Follow patterns in `tools/code-review/best-practices.md`
3. **Pre-commit**: Run `.agent/scripts/quality-check.sh`

### Documentation Lookup

Use Context7 MCP for real-time documentation:
- Framework APIs
- Library patterns
- Best practices

### Data Handling

For LLM-optimized data exchange:
- TOON format for structured data (see `tools/context/toon.md`)
- Token-efficient serialization

### Git Safety Practices

**Before destructive operations** (reset, clean, rebase, checkout with changes):

```bash
# Protect ALL work including untracked files
git stash --include-untracked -m "safety: before [operation]"

# After operation, restore if needed
git stash pop
```

**Why this matters**: `git restore` only recovers tracked files. Untracked new files are permanently lost without stash.

**Safe workflow**:
1. `git stash --include-untracked` before risky operations
2. Perform operation
3. `git stash pop` to restore work
4. If stash conflicts, `git stash show -p` to review
