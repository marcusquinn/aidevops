---
description: Import and convert external skills to aidevops format
mode: subagent
---

# Add Skill - External Skill Import System

Import skills from external sources (GitHub repos, gists) and convert them to aidevops format while preserving knowledge and handling conflicts intelligently.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `/add-skill <url>` | Import skill from GitHub |
| `/add-skill list` | List imported skills |
| `/add-skill check-updates` | Check for upstream changes |
| `/add-skill remove <name>` | Remove imported skill |

**Helper script:** `~/.aidevops/agents/scripts/add-skill-helper.sh`

## Architecture

```text
External Skill (GitHub)
        ↓
    Fetch & Detect Format
        ↓
    Check Conflicts with .agent/
        ↓
    Present Merge Options (if conflicts)
        ↓
    Convert to aidevops Format
        ↓
    Register in skill-sources.json
        ↓
    setup.sh creates symlinks to:
    - ~/.config/opencode/skills/
    - ~/.codex/skills/
    - ~/.claude/skills/
    - ~/.config/amp/tools/
```

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
```

**Conversion:** Preserve frontmatter, add `mode: subagent` and `imported_from: external`.

### AGENTS.md (aidevops/Windsurf)

Already in aidevops format.

**Conversion:** Direct copy, ensure `mode: subagent` is set.

### .cursorrules (Cursor)

Plain markdown without frontmatter.

**Conversion:** Wrap in markdown with generated frontmatter:
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

**Conversion:** Copy as-is, add frontmatter if missing.

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
1. Backup existing to `.agent/.backup/`
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

The helper script analyzes skill content to determine placement:

| Keywords | Category |
|----------|----------|
| deploy, vercel, coolify, docker, kubernetes | `tools/deployment/` |
| cloudflare, dns, hosting, domain | `services/hosting/` |
| browser, playwright, puppeteer | `tools/browser/` |
| seo, search, ranking, keyword | `seo/` |
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
      "local_path": ".agent/services/hosting/cloudflare.md",
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

| Skill | Repository | Description |
|-------|------------|-------------|
| Cloudflare | `dmmulroy/cloudflare-skill` | 60+ Cloudflare products |
| PDF | `anthropics/skills/pdf` | PDF manipulation toolkit |
| Vercel Deploy | `vercel-labs/agent-skills` | Instant Vercel deployments |
| Remotion | `remotion-dev/skills` | Video creation in React |
| Expo | `expo/skills` | React Native development |

Browse more at [skills.sh](https://skills.sh) leaderboard.

## Troubleshooting

### "Could not parse GitHub URL"

Ensure URL is in format:
- `owner/repo`
- `owner/repo/subpath`
- `https://github.com/owner/repo`

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
- Exact path match (`.agent/path/skill.md`)
- Directory match (`.agent/path/skill/`)

It does NOT check for semantic duplicates. Use `/add-skill list` to review.

## Related

- `scripts/commands/add-skill.md` - Slash command definition
- `scripts/add-skill-helper.sh` - Main implementation
- `scripts/skill-update-helper.sh` - Automated update checking
- `scripts/generate-skills.sh` - SKILL.md generation for aidevops agents
- `build-agent.md` - Agent design patterns
