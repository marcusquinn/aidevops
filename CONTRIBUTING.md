# Contributing to aidevops

Thanks for your interest in contributing! This guide will help you get started.

## Quick Start

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/aidevops.git`
3. Create a branch: `git checkout -b feature/your-feature`
4. Make your changes
5. Run tests: `./setup.sh` (installs locally for testing)
6. Commit with conventional commits: `git commit -m "feat: add new feature"`
7. Push and open a PR

## Development Setup

```bash
# Clone and install
git clone https://github.com/marcusquinn/aidevops.git
cd aidevops
./setup.sh

# Run quality checks before committing
.agent/scripts/linters-local.sh
```

## Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation only
- `refactor:` - Code change that neither fixes a bug nor adds a feature
- `chore:` - Maintenance tasks

## Code Standards

- Shell scripts: ShellCheck compliant, use `local var="$1"` pattern
- Markdown: Follow `.markdownlint.json` rules
- Quality target: SonarCloud A-grade

## Questions?

Open an issue or start a discussion. We're happy to help!
