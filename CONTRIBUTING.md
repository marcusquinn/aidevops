# Contributing to aidevops

Thanks for your interest in contributing! This guide will help you get started.

## Reporting Issues

**Preferred method:** Use `/log-issue-aidevops` in your AI assistant session. This command:

- Gathers diagnostic information automatically (version, OS, shell, assistant)
- Checks for duplicate issues before filing
- Produces a well-structured report with all required fields
- Submits directly via GitHub CLI

If you cannot use the CLI command, use the issue templates on GitHub. Blank issues are disabled — all reports must use a template. External issues are reviewed by a maintainer before entering the development pipeline.

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
.agents/scripts/linters-local.sh
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

## Scope of Contributions

aidevops is an opinionated framework. Architectural decisions — what the project integrates with, supports, tests against, or bundles — are made by maintainers.

**What we welcome from everyone:**

- Bug reports (especially destructive behaviour — deleting files, breaking configs)
- Feature requests (we'll assess fit and priority)
- Bug fixes and documentation improvements via PR

**What requires maintainer approval before implementation:**

- Adding integrations with third-party tools or services
- Changing default behaviours or configuration structure
- Adding new dependencies
- Modifying the agent framework architecture

**Third-party compatibility:** aidevops aims not to break other tools in your environment (we won't delete your files or overwrite your configs without opt-in). However, we don't guarantee compatibility with specific third-party tools and don't maintain test coverage for them. If you encounter a clash, report it — we'll fix destructive behaviour on our side, but we won't add integration code or test suites for external projects.

If you're unsure whether your contribution is in scope, open an issue first to discuss before investing time in a PR.

## Questions?

Open an issue or start a discussion. We're happy to help!
