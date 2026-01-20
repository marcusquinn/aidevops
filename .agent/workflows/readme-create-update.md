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

**Three Purposes of a README**:
1. **Local Development** - Get running in minutes
2. **Understanding the System** - How it works at a high level
3. **Production Deployment** - Ship and maintain it

**Core Principles**:
- Explore codebase BEFORE writing (detect stack, deployment, structure)
- Prioritize maintainability over exhaustive detail
- Avoid patterns that cause staleness (hardcoded counts, version numbers)
- Include AI-CONTEXT blocks for AI-readable documentation
- Point to source files rather than duplicate content

**Commands**:

```bash
# Create/update full README
/readme

# Update specific sections only
/readme --sections "installation,usage"
```

**When to use `--sections`**:
- After adding a feature (update usage/API sections)
- After changing installation process
- After adding troubleshooting for a new issue
- When full regeneration would lose custom content

<!-- AI-CONTEXT-END -->

## Before Writing

### Step 1: Deep Codebase Exploration

**CRITICAL**: Explore the codebase thoroughly before writing. Never assume - verify.

**Detect Project Type**:

| File | Indicates |
|------|-----------|
| `package.json` | Node.js/JavaScript/TypeScript |
| `Cargo.toml` | Rust |
| `go.mod` | Go |
| `requirements.txt`, `pyproject.toml` | Python |
| `Gemfile` | Ruby |
| `composer.json` | PHP |
| `*.sln`, `*.csproj` | .NET |
| `setup.sh`, `Makefile` only | Shell/scripts project |

**Detect Deployment Platform**:

| File | Platform |
|------|----------|
| `Dockerfile`, `docker-compose.yml` | Docker |
| `fly.toml` | Fly.io |
| `vercel.json`, `.vercel/` | Vercel |
| `netlify.toml` | Netlify |
| `render.yaml` | Render |
| `railway.json` | Railway |
| `app.yaml` | Google App Engine |
| `Procfile` | Heroku-like |
| `.ebextensions/` | AWS Elastic Beanstalk |
| `serverless.yml` | Serverless Framework |
| `k8s/`, `kubernetes/` | Kubernetes |
| `terraform/`, `*.tf` | Terraform/IaC |
| `config/deploy.yml` | Kamal |
| `coolify.json` | Coolify |

**Gather Information**:

```bash
# Project structure (high-level)
ls -la
ls -la src/ app/ lib/ bin/ 2>/dev/null

# Package info
cat package.json 2>/dev/null | jq '{name, description, scripts}' 
cat Cargo.toml 2>/dev/null | head -20
cat pyproject.toml 2>/dev/null | head -30

# Config files
ls -la *.config.* .env.example .env.sample 2>/dev/null

# CI/CD
ls -la .github/workflows/ .gitlab-ci.yml 2>/dev/null
```

### Step 2: Check Existing README

If README.md exists:
1. Read current content fully
2. Identify sections that are accurate vs outdated
3. Preserve custom content (badges, specific instructions, user additions)
4. **Adapt to existing structure** - don't reorganize unless requested
5. Update only what needs updating

### Step 3: Ask Only If Critical

Only ask the user if you cannot determine:
- What the project does (if not obvious from code/package.json)
- Specific deployment credentials or URLs needed
- Business context that affects documentation

Otherwise, proceed with exploration and writing.

## README Structure

### Recommended Section Order (New READMEs)

1. **Title & Description** - What it is, who it's for
2. **Badges** (optional) - Quality signals, version, license
3. **Key Features** - Bullet list of capabilities
4. **Quick Start** - Fastest path to running
5. **Installation** - Detailed setup options
6. **Usage** - Common commands and examples
7. **Architecture** (complex projects) - High-level structure only
8. **Configuration** - Environment variables, config files
9. **Development** - Contributing, testing, building
10. **Deployment** - Production setup (platform-specific)
11. **Troubleshooting** - Common issues and solutions
12. **License & Credits**

### Section Templates

#### Title & Description

```markdown
# Project Name

Brief description of what the project does and who it's for. 2-3 sentences max.

> Optional tagline or key value proposition
```

#### Badges

Recommend relevant badges based on project:

| Category | When to Include |
|----------|-----------------|
| Build/CI | If CI configured |
| Code quality | If SonarCloud/Codacy/etc. configured |
| Coverage | If tests with coverage |
| Version | If published package |
| License | Always for open source |
| Downloads | If published package with traction |

```markdown
[![Build Status](https://github.com/user/repo/workflows/CI/badge.svg)](https://github.com/user/repo/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
```

#### Quick Start

````markdown
## Quick Start

```bash
# Install
npm install -g project-name

# Run
project-name start
```

Open [http://localhost:3000](http://localhost:3000)
````

#### Architecture (High-Level Only)

**IMPORTANT**: Keep directory structures maintainable.

````markdown
## Architecture

```text
project/
├── src/           # Source code
│   ├── api/       # API routes
│   └── lib/       # Shared utilities
├── tests/         # Test files
└── docs/          # Documentation
```

See `docs/architecture.md` for detailed documentation.
````

**Avoid**:
- Listing every file (goes stale immediately)
- Deep nesting beyond 2-3 levels
- Line counts or file sizes
- Specific file names that may change

#### Configuration

````markdown
## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | - |
| `PORT` | Server port | `3000` |

Copy `.env.example` to `.env` and configure:

```bash
cp .env.example .env
```
````

#### Troubleshooting

````markdown
## Troubleshooting

### Connection refused on port 3000

**Cause**: Port already in use or server not started.

**Solution**:
```bash
# Check what's using the port
lsof -i :3000

# Use different port
PORT=3001 npm start
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
# Good: Points to source
See `src/config/defaults.ts` for all configuration options.

# Bad: Duplicates source (will drift)
The available options are:
- option1: does X
- option2: does Y
[... lines that will go stale]
```

### AI-CONTEXT Blocks

For AI-readable documentation, include condensed context:

```markdown
<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: One-line description
- **Stack**: Node.js, PostgreSQL, Redis
- **Entry**: `src/index.ts`

**Key Commands**:
- `npm start` - Run development server
- `npm test` - Run tests

<!-- AI-CONTEXT-END -->
```

### Collapsible Sections

For detailed content most readers can skip, use collapsible sections **uncollapsed by default**:

```markdown
<details open>
<summary>Advanced Configuration</summary>

Detailed configuration options here...

</details>
```

Users collapse sections they've read or don't need. Don't hide important content by default.

## Platform-Specific Guidance

### Node.js Projects

- Document `engines` requirements from package.json
- List key scripts from package.json
- Note package manager (npm, yarn, pnpm, bun)
- Include TypeScript setup if applicable

### Python Projects

- Specify Python version requirements
- Document virtual environment setup
- Include pip/poetry/uv installation options
- Note system dependencies (libpq-dev, etc.)

### Docker Projects

- Include both Docker and non-Docker setup paths
- Document required environment variables
- Provide docker-compose examples for local dev
- Note volume mounts for development

### Monorepos

- Document workspace structure at high level
- Explain package relationships briefly
- Provide commands for specific packages
- Note shared dependencies

## Updating Existing READMEs

When using `/readme --sections`:

1. **Read entire existing README first**
2. **Preserve structure** - Don't reorganize sections
3. **Preserve custom content** - User additions, specific examples
4. **Update only specified sections**
5. **Maintain consistent style** with existing content

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
