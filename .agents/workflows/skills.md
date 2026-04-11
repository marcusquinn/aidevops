---
description: Discover, explore, and manage installed AI agent skills and subagents
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Interactive skill discovery and management. Search, browse, describe, and get recommendations for installed skills, native subagents, and imported community skills.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Operation Mode

| Argument pattern | Action |
|-----------------|--------|
| empty / "help" | Show available commands and quick examples |
| free-text query / "search" | `skills-helper.sh search "$ARGUMENTS"` |
| "search --registry" / "--online" | `skills-helper.sh search --registry "$ARGUMENTS"` |
| "browse" [category] | `skills-helper.sh browse [category]` |
| "describe" / "show" \<name\> | `skills-helper.sh describe <name>` |
| "info" \<name\> | `skills-helper.sh info <name> [--json]` |
| "list" [filter] | `skills-helper.sh list [--imported\|--native]` |
| "categories" / "cats" | `skills-helper.sh categories` |
| "recommend" \<task\> | `skills-helper.sh recommend "<task>"` |
| "install" \<owner/repo@skill\> | `skills-helper.sh install <owner/repo@skill>` |
| "registry" / "online" \<query\> | `skills-helper.sh search --registry "$ARGUMENTS"` |
| "add" \<source\> | `add-skill-helper.sh add <source>` |
| "update" / "check" | `skill-update-helper.sh check` |
| "remove" \<name\> | `add-skill-helper.sh remove <name>` |

All scripts at `~/.aidevops/agents/scripts/`.

### Step 2: Present Results

Format output conversationally:

- **Search**: List matching skills with category and type (native/imported)
- **Browse**: Skills grouped by category with descriptions
- **Describe**: Full description, subagents, preview, and usage hints
- **Recommend**: Matched categories with relevant skills and usage tips
- **Registry search**: Results from skills.sh with install count and URL

**No local results** → proactively offer: `"No local skills found. Try: /skills search --registry <query>"`

### Step 3: Offer Follow-up Actions

```text
Next steps:
1. /skills describe <name>              — Get full details on a skill
2. /skills browse <category>            — Explore a category
3. /skills recommend "<task>"           — Get task-specific suggestions
4. /skills search --registry "<query>"  — Search the public skills.sh registry
5. /skills install <owner/repo@skill>   — Install from the public registry
6. aidevops skill add <repo>            — Import a community skill
```

## Conversational Mode

Interpret natural language and map to the appropriate command:

- "What skills do I have for browser automation?" → search "browser automation"
- "Show me all SEO tools" → browse seo
- "What does the playwright skill do?" → describe playwright
- "I need to deploy a Next.js app" → recommend "deploy Next.js app"
- "How many skills are installed?" → list, report count
- "Are there any public skills for X?" → search --registry "X"
- "Install the vercel browser skill" → install vercel-labs/agent-browser@agent-browser

## Related

- `scripts/skills-helper.sh` — CLI implementation
- `scripts/add-skill-helper.sh` — Skill import from GitHub/ClawdHub
- `scripts/skill-update-helper.sh` — Upstream update checking
- `scripts/generate-skills.sh` — SKILL.md stub generation
- `scripts/commands/add-skill.md` — Import command documentation
- `subagent-index.toon` — Full subagent registry
