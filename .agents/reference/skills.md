<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Skills & Cross-Tool

Import: `aidevops skill add <source>` (→ `*-skill.md` suffix)

**Discover**: `aidevops skills` or `/skills`. Subcommands: `search`, `browse`, `describe`, `categories`, `recommend`, `list [--imported]`

**Online registry** ([skills.sh](https://skills.sh/)):

```bash
aidevops skills search --registry "browser automation"
aidevops skills install vercel-labs/agent-browser@agent-browser
```

Local search with no results → `/skills` suggests the public registry automatically.

**Persistence**: `~/.aidevops/agents/`, tracked in `configs/skill-sources.json`. Daily auto-update. Only `custom/` and `draft/` survive `aidevops update`.

## Related

- `scripts/commands/add-skill.md` — Add a new skill
- `scripts/commands/skills.md` — Skills management
- `reference/services.md` — Services & Integrations index
