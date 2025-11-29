# Memory Template Directory

**Security Notice: This is a template directory only.**

## Actual Usage Location

Personal memory files should be stored in:
`~/.agent/memory/`

## Purpose

This template directory:

1. **Documents the structure** for memory usage
2. **Provides examples** of how to organize persistent data
3. **Maintains framework completeness** without personal data
4. **Guides AI assistants** on preference tracking

## Usage

```bash
# Use the personal directory for actual work
mkdir -p ~/.agent/memory/{patterns,preferences,configurations,history}

# Store successful patterns
echo "bulk-operations: Use Python scripts for universal fixes" > ~/.agent/memory/patterns/quality-fixes.txt

# Remember user preferences
echo "preferred_approach=bulk_operations" > ~/.agent/memory/preferences/user-settings.conf

# Cache configuration discoveries
echo "sonarcloud_project=marcusquinn_aidevops" > ~/.agent/memory/configurations/quality-tools.conf

# Track operation history
echo "$(date): Successfully fixed 50 quality issues with bulk script" >> ~/.agent/memory/history/operations.log
```

## Recommended Structure

```
~/.agent/memory/
├── patterns/           # Successful operation patterns
│   ├── quality-fixes.txt
│   ├── deployment-patterns.txt
│   └── troubleshooting.txt
├── preferences/        # User customizations (see Developer Preferences below)
│   ├── coding-style.md
│   ├── tool-preferences.md
│   ├── workflow-settings.md
│   └── project-specific/
│       ├── wordpress.md
│       └── nodejs.md
├── configurations/     # Configuration discoveries
│   ├── quality-tools.conf
│   ├── api-endpoints.conf
│   └── service-configs.conf
└── history/           # Operation history
    ├── operations.log
    ├── successful-fixes.log
    └── learning-notes.txt
```

## Developer Preferences Memory

### Purpose

Maintain a consistent record of developer preferences across coding sessions to:

- Ensure AI assistants provide assistance aligned with the developer's preferred style
- Reduce the need for developers to repeatedly explain their preferences
- Create a persistent context across tools and sessions

### How AI Assistants Should Use Preferences

1. **Before starting work**: Check `~/.agent/memory/preferences/` for relevant preferences
2. **During development**: Apply established preferences to suggestions and code
3. **When feedback is given**: Update preference files to record new preferences
4. **When switching projects**: Check for project-specific preference files

### Preference Categories to Track

#### Code Style Preferences

```markdown
# ~/.agent/memory/preferences/coding-style.md

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
# ~/.agent/memory/preferences/documentation.md

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
# ~/.agent/memory/preferences/workflow.md

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
# ~/.agent/memory/preferences/tools.md

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
# ~/.agent/memory/preferences/project-specific/wordpress.md

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
# ~/.agent/memory/preferences/environment-issues.md

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
- **Use ~/.agent/memory/** for all actual operations
- **This directory is version controlled** - keep it clean
- **Respect privacy** - be mindful of what you store
- **Update preferences** when developer feedback indicates a change

---
**Generated by**: AI DevOps Framework
**Personal Directory**: ~/.agent/memory/
