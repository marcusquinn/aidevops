---
description: Create or update README.md for the current project
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Create or update README.md for the current project.

**Use `--sections`** when adding a feature, changing install process, discovering a common issue, or when a full update would lose custom content. **Use full `/readme`** for new projects, significantly outdated docs, major restructuring, or explicit user request.

## Usage

```bash
/readme                                        # Full README (default)
/readme --sections "installation,usage"        # Partial update
/readme --sections "installation,usage,config" # Multiple sections
```

## Workflow

1. **Parse arguments** — check for `--sections` flag
2. **Load guidance** — read `workflows/readme-create-update.md`
3. **Explore codebase** — detect project type, deployment platform, existing README, key info
4. **Generate/update** — follow workflow section order; preserve structure for partial updates
5. **Confirm changes** — present diff and ask before writing

## Section Mapping

| Argument | Sections Updated | Use when |
|----------|-----------------|----------|
| `installation` | Installation, Prerequisites, Quick Start | Added Docker support, changed setup steps |
| `usage` | Usage, Commands, Examples, API | Added CLI commands, new endpoints |
| `config` | Configuration, Environment Variables | Changed env vars, new config options |
| `architecture` | Architecture, Project Structure | Restructured codebase |
| `troubleshooting` | Troubleshooting | Fixed common issue |
| `deployment` | Deployment, Production Setup | Added deployment target |
| `badges` | Badge section only | CI status changed |
| `all` | Full regeneration | Same as no flag |

## Dynamic Counts (aidevops repo)

Use `~/.aidevops/agents/scripts/readme-helper.sh check|update|update --apply` to manage stale counts.

## Related

- `workflows/readme-create-update.md` - Full workflow guidance
- `workflows/changelog.md` - Changelog updates
- `workflows/wiki-update.md` - Wiki documentation
- `scripts/readme-helper.sh` - Dynamic count management
