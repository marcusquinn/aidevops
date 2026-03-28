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

- **Purpose**: Generate comprehensive, maintainable README.md files
- **Trigger**: `/readme` command or `@readme-create-update` mention
- **Output**: README.md in project root (or specified location)

**Three Purposes**: (1) Local Development — get running in minutes, (2) Understanding the System — high-level how it works, (3) Production Deployment — ship and maintain it.

**Core Principles**:
- Explore codebase BEFORE writing (detect stack, deployment, structure)
- Prioritize maintainability over exhaustive detail
- Avoid staleness patterns (hardcoded counts, version numbers)
- Use approximate counts: `~15 agents`, `100+ scripts`
- Include AI-CONTEXT blocks; point to source files rather than duplicate content

**Dynamic Counts (aidevops repo)**: `readme-helper.sh check|counts|update [--apply]`

**Commands**: `/readme` (full) | `/readme --sections "installation,usage"` (partial)

**When to use `--sections`**: After adding a feature, changing install process, adding troubleshooting, or when full regeneration would lose custom content.

<!-- AI-CONTEXT-END -->

## Before Writing

### Step 1: Explore Codebase

**CRITICAL**: Explore thoroughly before writing. Never assume — verify.

**Detect Project Type** (check for these files):

| File | Stack | File | Stack |
|------|-------|------|-------|
| `package.json` | Node.js/JS/TS | `Cargo.toml` | Rust |
| `go.mod` | Go | `requirements.txt`, `pyproject.toml` | Python |
| `Gemfile` | Ruby | `composer.json` | PHP |
| `*.sln`, `*.csproj` | .NET | `setup.sh`, `Makefile` only | Shell |

**Detect Deployment Platform**:

| File | Platform | File | Platform |
|------|----------|------|----------|
| `Dockerfile` | Docker | `fly.toml` | Fly.io |
| `vercel.json` | Vercel | `netlify.toml` | Netlify |
| `render.yaml` | Render | `railway.json` | Railway |
| `Procfile` | Heroku-like | `serverless.yml` | Serverless |
| `k8s/` | Kubernetes | `terraform/` | Terraform |
| `config/deploy.yml` | Kamal | `coolify.json` | Coolify |

**Gather Information**:

```bash
ls -la; ls -la src/ app/ lib/ bin/ 2>/dev/null
cat package.json 2>/dev/null | jq '{name, description, scripts}'
ls -la *.config.* .env.example .github/workflows/ 2>/dev/null
```

### Step 2: Check Existing README

If README.md exists: read fully, identify accurate vs outdated sections, preserve custom content, **adapt to existing structure** (don't reorganize unless requested), update only what needs updating.

### Step 3: Ask Only If Critical

Only ask if you cannot determine: what the project does, deployment credentials/URLs, or business context. Otherwise proceed.

## README Structure

### Recommended Section Order (New READMEs)

1. Title & Description — what it is, who it's for
2. Badges (optional) — CI, quality, version, license
3. Key Features — bullet list
4. Quick Start — fastest path to running
5. Installation — detailed setup
6. Usage — commands and examples
7. Architecture (complex projects) — high-level only
8. Configuration — env vars, config files
9. Development — contributing, testing, building
10. Deployment — production setup (platform-specific)
11. Troubleshooting — common issues
12. License & Credits

### Section Templates

**Title & Description**:
```markdown
# Project Name
Brief description — what it does and who it's for. 2-3 sentences max.
> Optional tagline
```

**Badges** — include when configured: Build/CI, Code quality, Coverage, Version (published packages), License (always for OSS), Downloads (published with traction).

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

**Architecture** — keep directory structures maintainable (2-3 levels max, no file names that change):
````markdown
## Architecture
```text
project/
├── src/    # Source code
├── tests/  # Test files
└── docs/   # Documentation
```
See `docs/architecture.md` for details.
````

**Configuration**:
````markdown
## Configuration
| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | - |
| `PORT` | Server port | `3000` |

```bash
cp .env.example .env
```
````

**Troubleshooting**:
````markdown
## Troubleshooting
### Connection refused on port 3000
**Cause**: Port in use. **Solution**: `lsof -i :3000` then `PORT=3001 npm start`
````

## Maintainability Guidelines

### Patterns That Cause Staleness

| Pattern | Problem | Alternative |
|---------|---------|-------------|
| `"32 services supported"` | Count changes | `"30+ services"` or omit |
| `"Version 2.5.1"` | Outdated quickly | Badge or omit |
| `"Last updated: 2024-01-15"` | Always wrong | Rely on git history |
| Full file listings | Files change constantly | High-level structure only |
| Inline code examples from source | Drift from actual code | Point to source files |
| Hardcoded URLs | URLs change | Relative links where possible |

### Point to Source, Don't Duplicate

```markdown
# Good: See `src/config/defaults.ts` for all configuration options.
# Bad: The available options are: option1: does X, option2: does Y [will go stale]
```

### AI-CONTEXT Blocks

```markdown
<!-- AI-CONTEXT-START -->
## Quick Reference
- **Purpose**: One-line description
- **Stack**: Node.js, PostgreSQL, Redis
- **Entry**: `src/index.ts`
**Key Commands**: `npm start` — dev server | `npm test` — run tests
<!-- AI-CONTEXT-END -->
```

### Collapsible Sections

Use `<details open>` for content most readers can skip — **uncollapsed by default** so users can collapse what they've read. Don't hide important content by default.

## Platform-Specific Guidance

| Platform | Key points |
|----------|-----------|
| **Node.js** | `engines` from package.json, key scripts, package manager (npm/yarn/pnpm/bun), TypeScript setup |
| **Python** | Python version, venv setup, pip/poetry/uv options, system deps (libpq-dev, etc.) |
| **Docker** | Both Docker and non-Docker paths, required env vars, docker-compose for local dev, volume mounts |
| **Monorepo** | Workspace structure, package relationships, per-package commands, shared deps |

## Updating Existing READMEs

When using `/readme --sections`:
1. Read entire existing README first
2. Preserve structure — don't reorganize
3. Preserve custom content — user additions, specific examples
4. Update only specified sections
5. Maintain consistent style

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

- [ ] Can someone clone and run in under 5 minutes?
- [ ] Are all commands copy-pasteable?
- [ ] Architecture section high-level enough to stay accurate?
- [ ] No hardcoded counts or versions that will drift?
- [ ] Code examples point to source files where possible?
- [ ] Troubleshooting covers common issues?
- [ ] Environment variables documented with examples?
- [ ] License clearly stated?
- [ ] Badges reflect actual project status?

## Related Workflows

- `workflows/changelog.md` — Changelog updates
- `workflows/version-bump.md` — Version bumping
- `workflows/wiki-update.md` — Wiki documentation
- `scripts/commands/full-loop.md` — Full development loop
