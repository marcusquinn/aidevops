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

Update `.wiki/` to reflect the latest codebase state. Changes pushed to `main` auto-sync via `.github/workflows/sync-wiki.yml`.

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

```bash
.agents/scripts/context-builder-helper.sh compress .
```

Reference `repomix-instruction.md` for guidelines. Use Augment Context Engine or Repomix to understand architecture, new features, service integrations, and workflows since last update.

## Step 2: Review and Identify Updates

### Source of Truth

| Wiki Section | Source |
|--------------|--------|
| Version | `VERSION` file |
| Service count | `.agents/services/` |
| Script count | `ls .agents/scripts/*.sh \| wc -l` |
| MCP integrations | `configs/` |
| Workflows | `.agents/workflows/` |
| Agent structure | `.agents/AGENTS.md` |

### Checklist

- [ ] Version matches `VERSION`
- [ ] Service and script counts are current
- [ ] MCP integrations list is current
- [ ] Workflow guides reflect actual workflows
- [ ] Code examples are accurate

### Update Triggers

1. **New release** → update version in `Home.md`
2. **New service** → update `Providers.md`, `MCP-Integrations.md`
3. **New workflow** → update `Workflows-Guide.md`
4. **Architecture changes** → update `The-Agent-Directory.md`
5. **Setup changes** → update `Getting-Started.md`

## Step 3: Update Wiki Pages

| Page | Key Rules |
|------|-----------|
| `Home.md` | Concise; version prominent; link to detail pages, don't duplicate |
| `Getting-Started.md` | Test all install commands; verify paths; keep prerequisites current |
| `The-Agent-Directory.md` | Reflect actual directory structure; update script counts |
| `MCP-Integrations.md` | List all MCP servers from `configs/`; include config snippets and env vars |
| `Workflows-Guide.md` | List all workflows from `.agents/workflows/` with brief descriptions |

Style: tables for structured info, short paragraphs, practical examples, no jargon.

## Step 4: Validate and Commit

```bash
.agents/scripts/markdown-formatter.sh lint .wiki/
.agents/scripts/version-manager.sh validate
```

- [ ] Code examples syntactically correct
- [ ] All file paths exist
- [ ] All links resolve
- [ ] Version numbers consistent
- [ ] No placeholder text remains

```bash
git add .wiki/
git commit -m "docs(wiki): update wiki for v{VERSION}

- Updated version references
- Added new service integrations
- Refreshed workflow documentation"
```

Pushing `.wiki/` changes to `main` triggers sync — no manual wiki editing needed.

## Troubleshooting

**Wiki not syncing:** Check GitHub Actions status → verify `.wiki/` committed → confirm workflow has write permissions → check for merge conflicts.

**Link format** — no `.md` extension, no relative path:

```markdown
[Getting Started](Getting-Started)   # correct
[Getting Started](Getting-Started.md) # incorrect
```

**Version mismatch:**

```bash
rg "v[0-9]+\.[0-9]+\.[0-9]+" .wiki/
cat VERSION
```

## Related

- `repomix-instruction.md` — codebase context instructions
- `.agents/tools/context/augment-context-engine.md` — Augment setup
- `.agents/tools/context/context-builder.md` — Repomix wrapper
- `.github/workflows/sync-wiki.yml` — auto-sync workflow
