# Wiki Update Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Update GitHub wiki from latest codebase state
- **Wiki Location**: `.wiki/` directory (synced via GitHub Actions)
- **Sync Workflow**: `.github/workflows/sync-wiki.yml`
- **Context Tools**: Augment Context Engine, Repomix

**Key Files**:

| File | Purpose |
|------|---------|
| `.wiki/Home.md` | Landing page |
| `.wiki/_Sidebar.md` | Navigation structure |
| `.wiki/Getting-Started.md` | Installation guide |
| `.wiki/The-Agent-Directory.md` | Framework structure |
| `repomix-instruction.md` | Codebase context instructions |

**Workflow**:

1. Build codebase context (Augment/Repomix)
2. Review current wiki against codebase
3. Update wiki pages with changes
4. Commit to `.wiki/` directory
5. Push triggers auto-sync to GitHub wiki

<!-- AI-CONTEXT-END -->

## Overview

This workflow guides updating the GitHub wiki to reflect the latest state of the aidevops repository. The wiki provides high-level orientation and digestible documentation for users.

## Prerequisites

- Access to Augment Context Engine MCP (for semantic codebase understanding)
- Repomix available (for structured codebase packing)
- Write access to the repository

## Step 1: Build Codebase Context

### Using Augment Context Engine

Query the codebase for comprehensive understanding:

```text
"What is this project? Please use codebase retrieval tool to get the answer."
```

Key queries for wiki updates:

```text
# Architecture overview
"Describe the overall architecture and directory structure of this project"

# New features since last update
"What are the main features and capabilities of this framework?"

# Service integrations
"List all service integrations and their purposes"

# Workflow guides
"What workflows are available in .agent/workflows/?"
```

### Using Repomix

Generate structured codebase context:

```bash
# Compress mode for token-efficient overview
.agent/scripts/context-builder-helper.sh compress .

# Or use Repomix MCP directly
# pack_codebase with compress=true for ~80% token reduction
```

Reference `repomix-instruction.md` for codebase understanding guidelines.

## Step 2: Review Current Wiki State

### Wiki Structure

```text
.wiki/
├── Home.md                    # Landing page, version, quick start
├── _Sidebar.md                # Navigation structure
├── Getting-Started.md         # Installation and setup
├── For-Humans.md              # Non-technical overview
├── Understanding-AGENTS-md.md # How AI guidance works
├── The-Agent-Directory.md     # Framework structure
├── Workflows-Guide.md         # Development processes
├── MCP-Integrations.md        # MCP server documentation
└── Providers.md               # Service provider details
```

### Review Checklist

- [ ] Version number matches `VERSION` file
- [ ] Service count matches actual integrations
- [ ] Script count matches `.agent/scripts/` contents
- [ ] MCP integrations list is current
- [ ] Workflow guides reflect actual workflows
- [ ] Code examples are accurate and working

## Step 3: Identify Updates Needed

### Compare Against Codebase

| Wiki Section | Source of Truth |
|--------------|-----------------|
| Version | `VERSION` file |
| Service count | `.agent/services/` + service `.md` files |
| Script count | `ls .agent/scripts/*.sh \| wc -l` |
| MCP integrations | `configs/` directory |
| Workflows | `.agent/workflows/` directory |
| Agent structure | `.agent/AGENTS.md` |

### Common Update Triggers

1. **New release** - Update version in `Home.md`
2. **New service integration** - Update `Providers.md`, `MCP-Integrations.md`
3. **New workflow** - Update `Workflows-Guide.md`
4. **Architecture changes** - Update `The-Agent-Directory.md`
5. **Setup changes** - Update `Getting-Started.md`

## Step 4: Update Wiki Pages

### Page-Specific Guidelines

#### Home.md

- Keep concise - this is the landing page
- Update version number prominently
- Maintain quick start simplicity
- Link to detailed pages, don't duplicate content

#### Getting-Started.md

- Test all installation commands
- Verify directory paths are correct
- Ensure example conversations are realistic
- Keep prerequisites current

#### The-Agent-Directory.md

- Reflect actual directory structure
- Update script counts
- Document new subdirectories
- Keep file conventions accurate

#### MCP-Integrations.md

- List all MCP servers from `configs/`
- Include configuration snippets
- Document required environment variables
- Note any setup prerequisites

#### Workflows-Guide.md

- List all workflows from `.agent/workflows/`
- Brief description of each
- Link to detailed workflow files

### Writing Style

- Use tables for structured information
- Keep paragraphs short (2-3 sentences)
- Include practical examples
- Avoid jargon - explain technical terms
- Use consistent formatting

## Step 5: Validate Changes

### Pre-Commit Checks

```bash
# Validate markdown formatting
.agent/scripts/markdown-formatter.sh lint .wiki/

# Check for broken internal links
# (wiki links use format: [Text](Page-Name))

# Verify version consistency
.agent/scripts/version-manager.sh validate
```

### Content Validation

- [ ] All code examples are syntactically correct
- [ ] All file paths exist in the repository
- [ ] All links resolve correctly
- [ ] Version numbers are consistent
- [ ] No placeholder text remains

## Step 6: Commit and Sync

### Commit Changes

```bash
git add .wiki/
git commit -m "docs(wiki): update wiki for v{VERSION}

- Updated version references
- Added new service integrations
- Refreshed workflow documentation"
```

### Automatic Sync

Pushing to `main` with changes in `.wiki/` triggers `.github/workflows/sync-wiki.yml`:

1. Clones the wiki repository
2. Copies `.wiki/` contents
3. Commits and pushes to wiki

No manual wiki editing needed - all changes go through `.wiki/` directory.

## Example: Full Wiki Update

```bash
# 1. Get current version
cat VERSION
# Output: 2.0.0

# 2. Count current resources
echo "Scripts: $(ls .agent/scripts/*.sh 2>/dev/null | wc -l)"
echo "Services: $(ls .agent/services/**/*.md 2>/dev/null | wc -l)"
echo "Workflows: $(ls .agent/workflows/*.md 2>/dev/null | wc -l)"

# 3. Build context (using Augment Context Engine)
# "Summarize all changes since the last wiki update"

# 4. Update wiki pages as needed

# 5. Validate
.agent/scripts/markdown-formatter.sh lint .wiki/

# 6. Commit
git add .wiki/
git commit -m "docs(wiki): sync wiki with v2.0.0 release"
git push origin main
```

## Quick Examples for Users

### Example 1: Check Available Services

```text
User: "What hosting services does aidevops support?"

AI reads .wiki/Providers.md and responds with the list of hosting
providers: Hostinger, Hetzner, Cloudflare, Vercel, Coolify, etc.
```

### Example 2: Get Started Quickly

```text
User: "How do I set up aidevops?"

AI reads .wiki/Getting-Started.md and provides:
1. Clone command
2. Setup instructions
3. First steps with AI assistant
```

### Example 3: Understand the Structure

```text
User: "What's in the .agent directory?"

AI reads .wiki/The-Agent-Directory.md and explains:
- scripts/ - 90+ automation helpers
- workflows/ - development process guides
- memory/ - context persistence
- *.md - service documentation
```

## Troubleshooting

### Wiki Not Syncing

1. Check GitHub Actions workflow status
2. Verify `.wiki/` changes are committed
3. Ensure workflow has write permissions
4. Check for merge conflicts in wiki repo

### Broken Links

Wiki links use GitHub wiki format:

```markdown
# Correct
[Getting Started](Getting-Started)

# Incorrect
[Getting Started](Getting-Started.md)
[Getting Started](./Getting-Started.md)
```

### Version Mismatch

```bash
# Check all version references
rg "v[0-9]+\.[0-9]+\.[0-9]+" .wiki/

# Update to match VERSION file
VERSION=$(cat VERSION)
# Then update .wiki/Home.md
```

## Related Documentation

- `repomix-instruction.md` - Codebase context instructions
- `.agent/tools/context/augment-context-engine.md` - Augment setup
- `.agent/tools/context/context-builder.md` - Repomix wrapper
- `.github/workflows/sync-wiki.yml` - Auto-sync workflow
