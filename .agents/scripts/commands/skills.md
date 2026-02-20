---
description: Discover, explore, and manage installed AI agent skills and subagents
agent: Build+
mode: subagent
---

Interactive skill discovery and management. Search, browse, describe, and get recommendations for installed skills, native subagents, and imported community skills.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Operation Mode

Parse `$ARGUMENTS` to determine what to run:

- If empty or "help": show available commands and quick examples
- If starts with "search" or is a free-text query: search for matching skills
- If "browse" [category]: browse skills by category
- If "describe" or "show" <name>: show detailed skill description
- If "info" <name>: show metadata (path, source, model tier)
- If "list" [filter]: list all skills with optional filter
- If "categories" or "cats": list all categories with counts
- If "recommend" <task>: suggest skills for a task description
- If "add" <source>: delegate to `aidevops skill add` for importing
- If "update" or "check": delegate to `aidevops skill check/update`
- If "remove" <name>: delegate to `aidevops skill remove`

### Step 2: Run Appropriate Command

**Search (most common — also handles free-text queries):**

```bash
~/.aidevops/agents/scripts/skills-helper.sh search "$ARGUMENTS"
```

**Browse categories:**

```bash
# Top-level categories
~/.aidevops/agents/scripts/skills-helper.sh browse

# Specific category
~/.aidevops/agents/scripts/skills-helper.sh browse tools/browser
```

**Describe a skill:**

```bash
~/.aidevops/agents/scripts/skills-helper.sh describe playwright
```

**Skill metadata:**

```bash
~/.aidevops/agents/scripts/skills-helper.sh info seo-audit-skill
~/.aidevops/agents/scripts/skills-helper.sh info playwright --json
```

**List skills:**

```bash
~/.aidevops/agents/scripts/skills-helper.sh list
~/.aidevops/agents/scripts/skills-helper.sh list --imported
~/.aidevops/agents/scripts/skills-helper.sh list --native
```

**Categories:**

```bash
~/.aidevops/agents/scripts/skills-helper.sh categories
```

**Recommendations:**

```bash
~/.aidevops/agents/scripts/skills-helper.sh recommend "scrape a website and extract product data"
```

**Import/manage (delegate to existing skill commands):**

```bash
~/.aidevops/agents/scripts/add-skill-helper.sh add <source>
~/.aidevops/agents/scripts/skill-update-helper.sh check
~/.aidevops/agents/scripts/add-skill-helper.sh remove <name>
```

### Step 3: Present Results

Format the output conversationally:

- **Search results**: List matching skills with category and type (native/imported)
- **Browse**: Show skills grouped by category with descriptions
- **Describe**: Full description, subagents, preview, and usage hints
- **Recommend**: Matched categories with relevant skills and usage tips

### Step 4: Offer Follow-up Actions

After presenting results, suggest relevant next steps:

```text
Next steps:
1. /skills describe <name>    — Get full details on a skill
2. /skills browse <category>  — Explore a category
3. /skills recommend "<task>" — Get task-specific suggestions
4. aidevops skill add <repo>  — Import a community skill
```

## Quick Reference

| Command | Purpose |
|---------|---------|
| `/skills` | Show help and quick examples |
| `/skills browser` | Search for browser-related skills |
| `/skills search "deploy"` | Search by keyword |
| `/skills browse tools` | Browse tools category |
| `/skills browse services` | Browse services category |
| `/skills describe playwright` | Full description of playwright |
| `/skills info seo-audit-skill` | Metadata for imported skill |
| `/skills list --imported` | List imported community skills |
| `/skills categories` | List all categories with counts |
| `/skills recommend "test my API"` | Get skill recommendations |

## Conversational Mode

When the user asks questions like:

- "What skills do I have for browser automation?" → Run search "browser automation"
- "Show me all SEO tools" → Run browse seo
- "What does the playwright skill do?" → Run describe playwright
- "I need to deploy a Next.js app" → Run recommend "deploy Next.js app"
- "How many skills are installed?" → Run list, report count
- "What categories are available?" → Run categories

Interpret natural language intent and map to the appropriate command.

## Related

- `scripts/skills-helper.sh` — CLI implementation
- `scripts/add-skill-helper.sh` — Skill import from GitHub/ClawdHub
- `scripts/skill-update-helper.sh` — Upstream update checking
- `scripts/generate-skills.sh` — SKILL.md stub generation
- `scripts/commands/add-skill.md` — Import command documentation
- `subagent-index.toon` — Full subagent registry
