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
- **Command doc**: `scripts/commands/readme.md` (section mapping, argument parsing, examples)

**Three Purposes**: Local Development · Understanding the System · Production Deployment

**Core Principles**:

- Explore codebase BEFORE writing (detect stack, deployment, structure)
- Prioritize maintainability over exhaustive detail
- Avoid staleness: no hardcoded counts, version numbers, or full file listings
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

### Step 2: Check Existing README

If README.md exists: read fully, identify accurate vs outdated sections, preserve custom content and structure, update only what needs updating. Don't reorganize unless requested.

### Step 3: Ask Only If Critical

Only ask if you cannot determine: what the project does, specific deployment credentials/URLs, or business context. Otherwise proceed.

## README Structure (Recommended Section Order)

1. **Title & Description** — what it is, who it's for (2-3 sentences max)
2. **Badges** (optional) — build/CI, code quality, version, license (only if configured)
3. **Key Features** — bullet list of capabilities
4. **Quick Start** — fastest path to running
5. **Installation** — detailed setup options
6. **Usage** — common commands and examples
7. **Architecture** (complex projects) — high-level structure only, max 2-3 levels deep
8. **Configuration** — environment variables table, point to `.env.example`
9. **Development** — contributing, testing, building
10. **Deployment** — production setup (platform-specific)
11. **Troubleshooting** — common issues with cause + fix commands
12. **License & Credits**

## Maintainability Guidelines

### Staleness Patterns to Avoid

| Pattern | Problem | Alternative |
|---------|---------|-------------|
| `"32 services supported"` | Count changes | `"30+ services"` or omit |
| `"Version 2.5.1"` | Outdated quickly | Badge (auto-updates) or omit |
| `"Last updated: 2024-01-15"` | Always wrong | Rely on git history |
| Full file listings | Files change constantly | High-level structure only |
| Inline code examples from source | Drift from actual code | Point to source files |
| Hardcoded URLs | URLs change | Relative links where possible |

### Key Rules

- **Point to source, don't duplicate**: `See src/config/defaults.ts for all options` > listing every option inline
- **AI-CONTEXT blocks**: Place `<!-- AI-CONTEXT-START -->` / `<!-- AI-CONTEXT-END -->` around Quick Reference sections for agent consumption
- **Collapsible sections**: Use `<details open>` for detailed content most readers can skip. Default open — users collapse what they've read. Don't hide important content by default.

## Platform-Specific Guidance

| Platform | Key Points |
|----------|-----------|
| **Node.js** | Document `engines` from package.json; list key scripts; note package manager; TypeScript setup if applicable |
| **Python** | Specify Python version; document venv setup; include pip/poetry/uv options; note system deps |
| **Docker** | Include both Docker and non-Docker paths; document env vars; provide docker-compose examples; note volume mounts |
| **Monorepo** | Document workspace structure at high level; explain package relationships; provide per-package commands |

## Updating Existing READMEs

When using `/readme --sections`: read entire existing README first, preserve structure and custom content, update only specified sections, maintain consistent style. See `scripts/commands/readme.md` for section mapping table.

## Quality Checklist

Before finalizing, verify:

- Can someone clone and run in under 5 minutes?
- All commands copy-pasteable?
- Architecture section high-level enough to stay accurate?
- No hardcoded counts or versions that will drift?
- Code examples point to source files where possible?
- Troubleshooting covers common issues?
- Environment variables documented with examples?
- License clearly stated?

## Related

- `workflows/changelog.md` — Changelog updates
- `workflows/version-bump.md` — Version bumping
- `workflows/wiki-update.md` — Wiki documentation
- `scripts/commands/full-loop.md` — Full development loop
- `scripts/commands/readme.md` — `/readme` command (arguments, section mapping, examples)
