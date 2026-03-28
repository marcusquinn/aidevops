---
description: Import and convert external skills to aidevops format
mode: subagent
---

# Add Skill - External Skill Import System

Ingest skills from external sources (GitHub repos, ClawdHub registry) and transpose them to aidevops format while preserving all knowledge and handling conflicts intelligently.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `/add-skill <url>` | Import skill from GitHub or ClawdHub |
| `/add-skill clawdhub:<slug>` | Import skill from ClawdHub registry |
| `/add-skill list` | List imported skills |
| `/add-skill check-updates` | Check for upstream changes |
| `/add-skill remove <name>` | Remove imported skill |

**Helper scripts:**
- `~/.aidevops/agents/scripts/add-skill-helper.sh` — Main import logic
- `~/.aidevops/agents/scripts/clawdhub-helper.sh` — ClawdHub browser-based fetcher

## Architecture

```text
External Skill (GitHub or ClawdHub)
        ↓
    Detect Source (GitHub URL / clawdhub: prefix / clawdhub.com URL)
        ↓
    Fetch & Detect Format
    ├── GitHub: git clone --depth 1
    └── ClawdHub: Playwright browser extraction (SPA)
        ↓
    Check Conflicts with .agents/
        ↓
    Present Merge Options (if conflicts)
        ↓
    Transpose to aidevops Format (see below)
        ↓
    Register in skill-sources.json
        ↓
    setup.sh creates symlinks to:
    - ~/.config/opencode/skills/
    - ~/.codex/skills/
    - ~/.claude/skills/
    - ~/.config/amp/tools/
```

## Transposition Rules

Ingested skills retain the `-skill` suffix as a provenance marker — this enables `skill-update-helper.sh` to identify and check all ingested skills for upstream changes. The internal structure is flattened to match our `{name}.md` + `{name}/` convention with flat, descriptively-named files.

### Entry Point Rename

Upstream `SKILL.md` → `{name}-skill.md` (named entry point at the target category level).

### Flatten Nested Directories

Upstream nested structure is flattened using prefix-based naming:

| Upstream path | Transposed path |
|---------------|-----------------|
| `SKILL.md` | `{name}-skill.md` |
| `references/SCHEMA.md` | `{name}-skill/schema.md` |
| `references/QUERIES.md` | `{name}-skill/queries.md` |
| `references/CHEATSHEET/01-schema.md` | `{name}-skill/cheatsheet-schema.md` |
| `references/CHEATSHEET/02-relations.md` | `{name}-skill/cheatsheet-relations.md` |
| `rules/authentication.md` | `{name}-skill/rules-authentication.md` |
| `rules/avatars.md` | `{name}-skill/rules-avatars.md` |

### Example: Upstream vs Transposed

```text
# Upstream (postgres-drizzle skill)
SKILL.md
references/
├── SCHEMA.md
├── QUERIES.md
├── MIGRATIONS.md
├── PERFORMANCE.md
├── RELATIONS.md
├── POSTGRES.md
├── CHEATSHEET.md
└── CHEATSHEET/
    ├── 01-schema.md
    ├── 02-relations.md
    ├── 03-queries.md
    ├── 04-mutations.md
    ├── 05-config.md
    └── 06-reference.md

# Transposed (aidevops format)
postgres-drizzle-skill.md                    # Entry point (was SKILL.md)
postgres-drizzle-skill/                      # Flat reference files
├── schema.md
├── queries.md
├── migrations.md
├── performance.md
├── relations.md
├── postgres.md
├── cheatsheet.md
├── cheatsheet-schema.md
├── cheatsheet-relations.md
├── cheatsheet-queries.md
├── cheatsheet-mutations.md
├── cheatsheet-config.md
└── cheatsheet-reference.md
```

### Benefits

- `ls {name}-skill/` shows all reference material at a glance
- `ls {name}-skill/cheatsheet*` groups all cheatsheet files
- Entry point is discoverable by filename alongside sibling agents
- `-skill` suffix enables automated upstream update detection
- Max depth is 2 levels from parent directory

## Supported Input Formats

### SKILL.md (OpenSkills/Claude Code)

The emerging standard for AI assistant skills.

**Structure:**

```markdown
---
name: skill-name
description: One sentence describing when to use this skill
---

# Skill Title

Instructions for the AI agent...

## How It Works
1. Step one
2. Step two

## Usage

```bash
command examples
```

**Transposition:** Preserve frontmatter, add `mode: subagent` and `imported_from: external`. Rename `SKILL.md` → `{name}-skill.md`. Flatten nested directories per transposition rules above.

### AGENTS.md (aidevops/Windsurf)

Already in aidevops format.

**Transposition:** Direct copy, ensure `mode: subagent` is set.

### .cursorrules (Cursor)

Plain markdown without frontmatter.

**Transposition:** Wrap in Markdown with generated frontmatter:

```markdown
---
description: Imported from .cursorrules
mode: subagent
imported_from: cursorrules
---
# {skill-name}

{original content}
```

### Raw Markdown

Any markdown file (README.md, etc.).

**Transposition:** Copy as-is, add frontmatter if missing. Rename to `{name}-skill.md`.

## Conflict Resolution

When importing a skill that conflicts with existing files:

### Option 1: Merge

Combine new content with existing. Best when:
- Existing file has custom additions you want to keep
- New skill adds complementary functionality

**Strategy:**
1. Keep existing frontmatter
2. Add "## Imported Content" section
3. Append new skill content
4. Note merge in skill-sources.json

### Option 2: Replace

Overwrite existing with imported. Best when:
- Existing file is outdated
- Imported skill is more comprehensive
- You want upstream as source of truth

**Strategy:**
1. Backup existing to `.agents/.backup/`
2. Replace with imported content
3. Note replacement in skill-sources.json

### Option 3: Separate

Use different name for imported skill. Best when:
- Both versions are valuable
- Different use cases
- Want to compare approaches

**Strategy:**
1. Prompt for new name
2. Create with new name
3. Both coexist independently

### Option 4: Skip

Cancel import. Best when:
- Existing is preferred
- Need to review before deciding
- Accidental import

## Category Detection

The helper script analyzes skill content to determine placement. Patterns are ordered from specific to generic — earlier matches take precedence.

| Keywords | Category |
|----------|----------|
| deploy, vercel, coolify, docker, kubernetes | `tools/deployment/` |
| cloudflare workers, cloudflare pages, wrangler | `services/hosting/` |
| cloudflare, dns, hosting, domain | `services/hosting/` |
| proxmox, hypervisor, virtualization | `services/hosting/` |
| calendar, caldav, ical, scheduling | `tools/productivity/` |
| clean architecture, hexagonal, ddd, domain-driven, cqrs, event sourcing | `tools/architecture/` |
| feature-sliced, fsd architecture, slice organization | `tools/architecture/` |
| postgresql, postgres, drizzle, prisma, typeorm, sequelize, knex | `services/database/` |
| mermaid, flowchart, sequence diagram, ER diagram, UML | `tools/diagrams/` |
| javascript, typescript, es6, es2020–es2024, ecmascript | `tools/programming/` |
| browser, playwright, puppeteer | `tools/browser/` |
| seo, search ranking, keyword research | `seo/` |
| git, github, gitlab | `tools/git/` |
| code review, lint, quality | `tools/code-review/` |
| credential, secret, password | `tools/credentials/` |

Default: `tools/{skill-name}/`

## Update Tracking

### skill-sources.json Schema

```json
{
  "version": "1.0.0",
  "skills": [
    {
      "name": "cloudflare",
      "upstream_url": "https://github.com/dmmulroy/cloudflare-skill",
      "upstream_commit": "abc123def456...",
      "local_path": ".agents/services/hosting/cloudflare.md",
      "format_detected": "skill-md",
      "imported_at": "2026-01-21T00:00:00Z",
      "last_checked": "2026-01-21T00:00:00Z",
      "merge_strategy": "added|merged|replaced",
      "notes": "Optional notes about the import"
    }
  ]
}
```

### Update Detection

```bash
# Check all skills for updates
~/.aidevops/agents/scripts/add-skill-helper.sh check-updates

# Output:
# UPDATE AVAILABLE: cloudflare
#   Current: abc123d
#   Latest:  def456g
#   Run: add-skill-helper.sh add dmmulroy/cloudflare-skill --force
#
# Up to date: vercel-deploy
```

## Integration with setup.sh

After importing skills, `setup.sh` creates symlinks:

```bash
# In setup.sh
create_skill_symlinks() {
    local skill_sources="$AGENTS_DIR/configs/skill-sources.json"
    
    if [[ -f "$skill_sources" ]] && command -v jq &>/dev/null; then
        # Create symlinks to various AI assistant skill directories
        jq -r '.skills[] | .local_path' "$skill_sources" | while read -r path; do
            local skill_name=$(basename "$path" .md)
            
            # OpenCode
            ln -sf "$AGENTS_DIR/$path" "$HOME/.config/opencode/skills/$skill_name/SKILL.md"
            
            # Codex
            ln -sf "$AGENTS_DIR/$path" "$HOME/.codex/skills/$skill_name/SKILL.md"
            
            # Claude Code
            ln -sf "$AGENTS_DIR/$path" "$HOME/.claude/skills/$skill_name/SKILL.md"
            
            # Amp
            ln -sf "$AGENTS_DIR/$path" "$HOME/.config/amp/tools/$skill_name.md"
        done
    fi
}
```

## Popular Skills to Import

### GitHub

| Skill | Repository | Description |
|-------|------------|-------------|
| Cloudflare | `dmmulroy/cloudflare-skill` | 60+ Cloudflare products |
| PDF | `anthropics/skills/pdf` | PDF manipulation toolkit |
| Vercel Deploy | `vercel-labs/agent-skills` | Instant Vercel deployments |
| Remotion | `remotion-dev/skills` | Video creation in React |
| Expo | `expo/skills` | React Native development |

Browse more at [skills.sh](https://skills.sh) leaderboard.

### ClawdHub

| Skill | Slug | Description |
|-------|------|-------------|
| CalDAV Calendar | `clawdhub:caldav-calendar` | CalDAV sync via vdirsyncer + khal |
| Proxmox Full | `clawdhub:proxmox-full` | Complete Proxmox VE management |

Browse more at [clawdhub.com](https://clawdhub.com) — vector search for agent skills.

## Troubleshooting

### "Could not parse source URL"

Ensure URL is in one of these formats:
- `owner/repo` (GitHub)
- `owner/repo/subpath` (GitHub)
- `https://github.com/owner/repo`
- `clawdhub:slug` (ClawdHub)
- `https://clawdhub.com/owner/slug` (ClawdHub)

### "Failed to clone repository"

- Check internet connection
- Verify repository exists and is public
- For private repos, ensure `gh auth login` is configured

### "jq not found"

Install jq for full functionality:

```bash
brew install jq  # macOS
apt install jq   # Ubuntu/Debian
```

### Conflicts not detected

The helper checks for:
- Exact path match (`.agents/path/skill.md`)
- Directory match (`.agents/path/skill/`)

It does NOT check for semantic duplicates. Use `/add-skill list` to review.

## Related

- `scripts/commands/add-skill.md` - Slash command definition
- `scripts/add-skill-helper.sh` - Main implementation
- `scripts/clawdhub-helper.sh` - ClawdHub browser-based fetcher
- `scripts/skill-update-helper.sh` - Automated update checking
- `scripts/generate-skills.sh` - SKILL.md generation for aidevops agents
- `build-agent.md` - Agent design patterns
