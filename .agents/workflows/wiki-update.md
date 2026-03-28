---
description: Update GitHub wiki from latest codebase state
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Wiki Update Workflow

Update the GitHub wiki (`.wiki/` directory) to reflect the latest codebase state. Changes pushed to `main` auto-sync via `.github/workflows/sync-wiki.yml`.

## Wiki Pages

| File | Purpose |
|------|---------|
| `.wiki/Home.md` | Landing page, version, quick start |
| `.wiki/_Sidebar.md` | Navigation structure |
| `.wiki/Getting-Started.md` | Installation and setup |
| `.wiki/For-Humans.md` | Non-technical overview |
| `.wiki/Understanding-AGENTS-md.md` | How AI guidance works |
| `.wiki/The-Agent-Directory.md` | Framework structure |
| `.wiki/Workflows-Guide.md` | Development processes |
| `.wiki/MCP-Integrations.md` | MCP server documentation |
| `.wiki/Providers.md` | Service provider details |

## Step 1: Build Codebase Context

Use **Augment Context Engine** or **Repomix** to understand current state:

- Architecture overview and directory structure
- Features and capabilities added since last update
- Service integrations and their purposes
- Available workflows in `.agents/workflows/`

```bash
# Token-efficient codebase overview
.agents/scripts/context-builder-helper.sh compress .
```

Reference `repomix-instruction.md` for codebase understanding guidelines.

## Step 2: Review and Identify Updates

### Source of Truth Mapping

| Wiki Section | Source |
|--------------|--------|
| Version | `VERSION` file |
| Service count | `.agents/services/` + service `.md` files |
| Script count | `ls .agents/scripts/*.sh \| wc -l` |
| MCP integrations | `configs/` directory |
| Workflows | `.agents/workflows/` directory |
| Agent structure | `.agents/AGENTS.md` |

### Review Checklist

- [ ] Version number matches `VERSION` file
- [ ] Service count matches actual integrations
- [ ] Script count matches `.agents/scripts/` contents
- [ ] MCP integrations list is current
- [ ] Workflow guides reflect actual workflows
- [ ] Code examples are accurate and working

### Common Update Triggers

1. **New release** — update version in `Home.md`
2. **New service integration** — update `Providers.md`, `MCP-Integrations.md`
3. **New workflow** — update `Workflows-Guide.md`
4. **Architecture changes** — update `The-Agent-Directory.md`
5. **Setup changes** — update `Getting-Started.md`

## Step 3: Update Wiki Pages

### Page Guidelines

| Page | Key Rules |
|------|-----------|
| `Home.md` | Keep concise; update version prominently; link to detail pages, don't duplicate |
| `Getting-Started.md` | Test all install commands; verify paths; keep prerequisites current |
| `The-Agent-Directory.md` | Reflect actual directory structure; update script counts |
| `MCP-Integrations.md` | List all MCP servers from `configs/`; include config snippets and env vars |
| `Workflows-Guide.md` | List all workflows from `.agents/workflows/` with brief descriptions |

### Writing Style

Use tables for structured info. Short paragraphs (2-3 sentences). Include practical examples. Avoid jargon. Consistent formatting.

## Step 4: Validate and Commit

### Pre-Commit Checks

```bash
# Validate markdown formatting
.agents/scripts/markdown-formatter.sh lint .wiki/

# Verify version consistency
.agents/scripts/version-manager.sh validate
```

### Content Validation

- [ ] All code examples are syntactically correct
- [ ] All file paths exist in the repository
- [ ] All links resolve correctly
- [ ] Version numbers are consistent
- [ ] No placeholder text remains

### Commit and Sync

```bash
git add .wiki/
git commit -m "docs(wiki): update wiki for v{VERSION}

- Updated version references
- Added new service integrations
- Refreshed workflow documentation"
```

Pushing to `main` with `.wiki/` changes triggers `.github/workflows/sync-wiki.yml` — no manual wiki editing needed.

## Troubleshooting

### Wiki Not Syncing

1. Check GitHub Actions workflow status
2. Verify `.wiki/` changes are committed
3. Ensure workflow has write permissions
4. Check for merge conflicts in wiki repo

### Wiki Link Format

```markdown
# Correct — no .md extension, no relative path
[Getting Started](Getting-Started)

# Incorrect
[Getting Started](Getting-Started.md)
[Getting Started](./Getting-Started.md)
```

### Version Mismatch

```bash
# Find all version references
rg "v[0-9]+\.[0-9]+\.[0-9]+" .wiki/

# Compare against VERSION file
cat VERSION
```

## Related

- `repomix-instruction.md` — codebase context instructions
- `.agents/tools/context/augment-context-engine.md` — Augment setup
- `.agents/tools/context/context-builder.md` — Repomix wrapper
- `.github/workflows/sync-wiki.yml` — auto-sync workflow
