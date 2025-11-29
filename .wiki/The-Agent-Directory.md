# The .agent Directory

Everything AI assistants need lives in `.agent/`. This page explains the structure and how to use it.

## Overview

```
.agent/
├── scripts/       # 90+ automation & helper scripts
├── workflows/     # Development process guides
├── memory/        # Context persistence templates
└── *.md           # Service documentation (80+ files)
```

**Key principle:** When referencing this repo with AI, use `@.agent` to include relevant context.

## scripts/ - Automation Helpers

### What's Here

90+ shell scripts for automating common tasks:

| Script Pattern | Purpose | Example |
|----------------|---------|---------|
| `*-helper.sh` | Service automation | `hostinger-helper.sh`, `hetzner-helper.sh` |
| `*-cli.sh` | CLI tool wrappers | `codacy-cli.sh`, `coderabbit-cli.sh` |
| `setup-*.sh` | Configuration wizards | `setup-local-api-keys.sh` |
| `quality-*.sh` | Code quality tools | `quality-check.sh`, `quality-fix.sh` |

### Using Scripts

```bash
# List all available scripts
ls ~/git/aidevops/.agent/scripts/

# Get help for any script
bash ~/git/aidevops/.agent/scripts/hostinger-helper.sh help

# Common pattern: service helper with command
bash ~/git/aidevops/.agent/scripts/[service]-helper.sh [command] [account] [target]
```

### Key Scripts

| Script | Description |
|--------|-------------|
| `quality-check.sh` | Run all quality checks |
| `quality-feedback-helper.sh` | Get CI/CD feedback via GitHub API |
| `setup-local-api-keys.sh` | Securely store API keys |
| `github-cli-helper.sh` | Enhanced GitHub operations |
| `hostinger-helper.sh` | Hostinger hosting management |

## workflows/ - Development Guides

### What's Here

Step-by-step process guides for common development tasks:

| File | Purpose |
|------|---------|
| `git-workflow.md` | Git practices and branching |
| `bug-fixing.md` | Bug fix and hotfix procedures |
| `feature-development.md` | Feature development lifecycle |
| `code-review.md` | Code review checklist |
| `release-process.md` | Semantic versioning and releases |
| `error-checking-feedback-loops.md` | CI/CD monitoring |
| `multi-repo-workspace.md` | Multi-repository safety |
| `wordpress-local-testing.md` | WordPress testing environments |

### When to Use Workflows

| Situation | Workflow |
|-----------|----------|
| Starting a new feature | `feature-development.md` |
| Fixing a bug | `bug-fixing.md` |
| Preparing a release | `release-process.md` |
| Reviewing code | `code-review.md` |
| CI/CD failures | `error-checking-feedback-loops.md` |
| Working across repos | `multi-repo-workspace.md` |

## memory/ - Context Persistence

### What's Here

Templates for AI assistants to maintain context across sessions:

```
memory/
├── README.md           # How to use memory
├── patterns/           # Successful approaches
├── preferences/        # User preferences
└── configurations/     # Discovered configs
```

### How It Works

AI assistants can:
1. **Store** learned patterns and preferences
2. **Retrieve** context in future sessions
3. **Update** as they learn more about your workflow

**Note:** Actual memory files are stored in `~/.agent/memory/` (outside Git).

## Service Documentation (*.md files)

### What's Here

80+ documentation files covering all integrated services:

| Category | Examples |
|----------|----------|
| Hosting | `hostinger.md`, `hetzner.md`, `cloudron.md` |
| Domains | `spaceship.md`, `101domains.md` |
| Quality | `codacy.md`, `coderabbit.md`, `sonarcloud.md` |
| Git | `github.md`, `gitlab.md`, `gitea.md` |
| WordPress | `mainwp.md`, `wordpress.md` |

### File Convention

- **Lowercase filenames** with hyphens
- **AI-CONTEXT blocks** for quick reference
- **Detailed sections** for comprehensive info

### Example Structure

```markdown
# Service Name

<!-- AI-CONTEXT-START -->
## Quick Reference
- Key fact 1
- Key fact 2
- Commands: list|connect|deploy
<!-- AI-CONTEXT-END -->

## Detailed Documentation
[... verbose content ...]
```

## How AI Uses This Directory

### 1. Task Understanding

AI reads relevant documentation to understand:
- Available operations
- Required credentials
- API endpoints

### 2. Script Execution

AI uses helper scripts for:
- Service operations
- Quality checks
- Automated fixes

### 3. Process Following

AI follows workflows for:
- Consistent development practices
- Proper release procedures
- Code review standards

## Extending the Framework

### Adding a New Service

1. Create `service-name.md` in `.agent/`
2. Create `service-name-helper.sh` in `.agent/scripts/`
3. Update `AGENTS.md` service categories
4. Add configuration template in `configs/`

### Adding a New Workflow

1. Create `workflow-name.md` in `.agent/workflows/`
2. Follow the template in `workflows/README.md`
3. Update the workflows README index

## Related Pages

- **[Understanding AGENTS.md](Understanding-AGENTS-md)** - AI instruction file
- **[Workflows Guide](Workflows-Guide)** - Development processes
- **[Getting Started](Getting-Started)** - Installation
