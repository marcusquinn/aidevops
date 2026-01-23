---
description: Import external skills from GitHub repositories into aidevops
agent: Build+
mode: subagent
---

Import an external skill from a GitHub repository, convert it to aidevops format, and register it for update tracking.

URL/Repo: $ARGUMENTS

## Quick Reference

```bash
# Import skill from GitHub (saved as *-skill.md)
/add-skill dmmulroy/cloudflare-skill
# → .agent/services/hosting/cloudflare-skill.md

# Import specific skill from multi-skill repo
/add-skill anthropics/skills/pdf
# → .agent/tools/pdf-skill.md

# Import with custom name
/add-skill vercel-labs/agent-skills --name vercel-deploy
# → .agent/tools/deployment/vercel-deploy-skill.md

# List imported skills
/add-skill list

# Check for updates
/add-skill check-updates
```

## Naming Convention

Imported skills are saved with a `-skill` suffix to distinguish them from native aidevops subagents:

| Type | Example | Managed by |
|------|---------|------------|
| Native subagent | `playwright.md` | aidevops team, evolves with framework |
| Imported skill | `playwright-skill.md` | Upstream repo, checked for updates |

This means:
- No name clashes between imports and native subagents
- `*-skill.md` glob finds all imports instantly
- `aidevops skill check` knows which files to check for upstream updates
- Issues with imported skills → check upstream; issues with native → evolve locally

## Workflow

### Step 1: Parse Input

Determine if the input is:
- A GitHub shorthand: `owner/repo` or `owner/repo/subpath`
- A full URL: `https://github.com/owner/repo`
- A command: `list`, `check-updates`, `remove <name>`

### Step 2: Run Helper Script

```bash
~/.aidevops/agents/scripts/add-skill-helper.sh add "$ARGUMENTS"
```

For other commands:

```bash
# List all imported skills
~/.aidevops/agents/scripts/add-skill-helper.sh list

# Check for upstream updates
~/.aidevops/agents/scripts/add-skill-helper.sh check-updates

# Remove a skill
~/.aidevops/agents/scripts/add-skill-helper.sh remove <name>
```

### Step 3: Handle Conflicts

If the skill conflicts with existing files, the helper will prompt:

1. **Merge** - Add new content to existing file (preserves both)
2. **Replace** - Overwrite existing with imported skill
3. **Separate** - Use a different name for the imported skill
4. **Skip** - Cancel the import

### Step 4: Post-Import

After successful import:

1. The skill is placed in `.agent/` following aidevops conventions
2. Registered in `.agent/configs/skill-sources.json` for update tracking
3. Run `./setup.sh` to create symlinks for other AI assistants

## Supported Formats

| Format | Detection | Conversion |
|--------|-----------|------------|
| SKILL.md | OpenSkills/Claude Code | Frontmatter preserved, content adapted |
| AGENTS.md | aidevops/Windsurf | Direct copy with mode: subagent |
| .cursorrules | Cursor | Wrapped in markdown with frontmatter |
| README.md | Generic | Copied as-is |

## Examples

```bash
# Import Cloudflare skill (60+ products)
/add-skill dmmulroy/cloudflare-skill

# Import PDF manipulation skill from Anthropic
/add-skill anthropics/skills/pdf

# Import Vercel deployment skill
/add-skill vercel-labs/agent-skills

# Import with force (overwrite existing)
/add-skill dmmulroy/cloudflare-skill --force

# Dry run (show what would happen)
/add-skill dmmulroy/cloudflare-skill --dry-run
```

## Update Tracking

Imported skills are tracked in `.agent/configs/skill-sources.json`:

```json
{
  "skills": [
    {
      "name": "cloudflare",
      "upstream_url": "https://github.com/dmmulroy/cloudflare-skill",
      "upstream_commit": "abc123...",
      "local_path": ".agent/services/hosting/cloudflare-skill.md",
      "format_detected": "skill-md",
      "imported_at": "2026-01-21T00:00:00Z",
      "last_checked": "2026-01-21T00:00:00Z",
      "merge_strategy": "added"
    }
  ]
}
```

Run `/add-skill check-updates` periodically to see if upstream skills have changed.

## Related

- `tools/build-agent/add-skill.md` - Detailed conversion logic and merge strategies
- `scripts/skill-update-helper.sh` - Automated update checking
- `scripts/generate-skills.sh` - SKILL.md stub generation for aidevops agents
