---
description: Create or update comprehensive README.md files for any project
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# README Create/Update Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Trigger**: `/readme` or `@readme-create-update`
- **Output**: `README.md` in project root (or specified location)

**Three Purposes**: Local Development · Understanding the System · Production Deployment

**Core Principles**:
- Explore codebase BEFORE writing (detect stack, deployment, structure)
- Prioritize maintainability over exhaustive detail
- Avoid staleness patterns: hardcoded counts, version numbers, full file listings
- Use approximate counts (`~15 agents`, `100+ scripts`); point to source files, don't duplicate

**Dynamic Counts (aidevops repo)**:

```bash
~/.aidevops/agents/scripts/readme-helper.sh check    # check staleness
~/.aidevops/agents/scripts/readme-helper.sh counts   # current counts
~/.aidevops/agents/scripts/readme-helper.sh update --apply  # apply updates
```

**Commands**:

```bash
/readme                              # full create/update
/readme --sections "installation,usage"  # update specific sections only
```

Use `--sections` after adding a feature, changing install steps, or when full regeneration would lose custom content.

<!-- AI-CONTEXT-END -->

## Before Writing

### Step 1: Detect Project Type and Deployment

**CRITICAL**: Explore before writing. Never assume — verify.

| File | Project Type | | File | Platform |
|------|--------------|-|------|----------|
| `package.json` | Node.js/JS/TS | | `Dockerfile`, `docker-compose.yml` | Docker |
| `Cargo.toml` | Rust | | `fly.toml` | Fly.io |
| `go.mod` | Go | | `vercel.json`, `.vercel/` | Vercel |
| `requirements.txt`, `pyproject.toml` | Python | | `netlify.toml` | Netlify |
| `Gemfile` | Ruby | | `render.yaml` | Render |
| `composer.json` | PHP | | `railway.json` | Railway |
| `*.sln`, `*.csproj` | .NET | | `serverless.yml` | Serverless |
| `setup.sh`, `Makefile` only | Shell/scripts | | `k8s/`, `*.tf` | K8s / Terraform |

**Gather Information**:

```bash
ls -la; ls -la src/ app/ lib/ bin/ 2>/dev/null
cat package.json 2>/dev/null | jq '{name,description,scripts}'
ls -la *.config.* .env.example .github/workflows/ 2>/dev/null
```

### Step 2: Check Existing README

If README.md exists: read fully → identify accurate vs outdated sections → preserve custom content and structure → update only what needs updating. Don't reorganize unless requested.

### Step 3: Ask Only If Critical

Only ask if you cannot determine: what the project does, specific deployment credentials/URLs, or business context. Otherwise proceed.

## README Structure

### Recommended Section Order (New READMEs)

1. Title & Description — what it is, who it's for
2. Badges (optional) — quality signals, version, license
3. Key Features — bullet list of capabilities
4. Quick Start — fastest path to running
5. Installation — detailed setup options
6. Usage — common commands and examples
7. Architecture (complex projects) — high-level structure only
8. Configuration — environment variables, config files
9. Development — contributing, testing, building
10. Deployment — production setup (platform-specific)
11. Troubleshooting — common issues and solutions
12. License & Credits

### Section Templates

**Title & Description**:
```markdown
# Project Name
Brief description of what the project does and who it's for. 2-3 sentences max.
> Optional tagline or key value proposition
```

**Badges** — include based on what's configured:

| Category | When to Include |
|----------|-----------------|
| Build/CI | If CI configured |
| Code quality | If SonarCloud/Codacy/etc. configured |
| Version | If published package |
| License | Always for open source |

```markdown
[![Build Status](https://github.com/user/repo/workflows/CI/badge.svg)](https://github.com/user/repo/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
```

**Quick Start**:
````markdown
## Quick Start
```bash
npm install -g project-name
project-name start
```
Open [http://localhost:3000](http://localhost:3000)
````

**Architecture** — high-level only:
````markdown
## Architecture
```text
project/
├── src/           # Source code
│   ├── api/       # API routes
│   └── lib/       # Shared utilities
└── tests/         # Test files
```
See `docs/architecture.md` for details.
````
Avoid: listing every file, deep nesting (>2-3 levels), line counts, specific filenames that may change.

**Configuration**:
````markdown
## Configuration
| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | - |
| `PORT` | Server port | `3000` |

Copy `.env.example` to `.env` and configure.
````

**Troubleshooting**:
````markdown
## Troubleshooting
### Connection refused on port 3000
**Cause**: Port in use or server not started.
```bash
lsof -i :3000        # check what's using the port
PORT=3001 npm start  # use different port
```
````

## Maintainability Guidelines

### Patterns That Cause Staleness

| Pattern | Problem | Alternative |
|---------|---------|-------------|
| `"32 services supported"` | Count changes | `"30+ services"` or omit |
| `"Version 2.5.1"` | Outdated quickly | Badge (auto-updates) or omit |
| `"Last updated: 2024-01-15"` | Always wrong | Rely on git history |
| Full file listings | Files change constantly | High-level structure only |
| Inline code examples from source | Drift from actual code | Point to source files |
| Hardcoded URLs | URLs change | Relative links where possible |

### Point to Source, Don't Duplicate

```markdown
# Good: points to source
See `src/config/defaults.ts` for all configuration options.

# Bad: duplicates source (will drift)
The available options are: option1: does X, option2: does Y ...
```

### AI-CONTEXT Blocks

```markdown
<!-- AI-CONTEXT-START -->
## Quick Reference
- **Purpose**: One-line description
- **Stack**: Node.js, PostgreSQL, Redis
- **Entry**: `src/index.ts`
**Key Commands**: `npm start` · `npm test`
<!-- AI-CONTEXT-END -->
```

### Collapsible Sections

Use `<details open>` for detailed content most readers can skip. Default open — users collapse what they've read. Don't hide important content by default.

## Platform-Specific Guidance

| Platform | Key Points |
|----------|-----------|
| **Node.js** | Document `engines` from package.json; list key scripts; note package manager (npm/yarn/pnpm/bun); TypeScript setup if applicable |
| **Python** | Specify Python version; document venv setup; include pip/poetry/uv options; note system deps (libpq-dev, etc.) |
| **Docker** | Include both Docker and non-Docker paths; document env vars; provide docker-compose examples; note volume mounts |
| **Monorepo** | Document workspace structure at high level; explain package relationships; provide per-package commands; note shared deps |

## Updating Existing READMEs

When using `/readme --sections`:

1. Read entire existing README first
2. Preserve structure — don't reorganize sections
3. Preserve custom content — user additions, specific examples
4. Update only specified sections
5. Maintain consistent style with existing content

### Section Mapping

| `--sections` value | Updates |
|--------------------|---------|
| `installation` | Installation, Prerequisites, Quick Start |
| `usage` | Usage, Commands, Examples, API |
| `config` | Configuration, Environment Variables |
| `architecture` | Architecture, Project Structure |
| `troubleshooting` | Troubleshooting |
| `deployment` | Deployment, Production Setup |
| `badges` | Badge section only |
| `all` | Full regeneration (default) |

## Quality Checklist

Before finalizing:

- [ ] Can someone clone and run in under 5 minutes?
- [ ] Are all commands copy-pasteable?
- [ ] Is architecture section high-level enough to stay accurate?
- [ ] No hardcoded counts or versions that will drift?
- [ ] Code examples point to source files where possible?
- [ ] Troubleshooting section covers common issues?
- [ ] Environment variables documented with examples?
- [ ] License clearly stated?
- [ ] Badges reflect actual project status?

## Related Workflows

- **Changelog updates**: `workflows/changelog.md`
- **Version bumping**: `workflows/version-bump.md`
- **Wiki documentation**: `workflows/wiki-update.md`
- **Full development loop**: `scripts/commands/full-loop.md`
