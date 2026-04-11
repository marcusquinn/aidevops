---
description: Create or update README.md for the current project
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Use `--sections` for targeted updates (adding a feature, changing install/config, preserving custom content). Omit for full regeneration (new projects, major restructuring, explicit request).

## Usage

```bash
/readme                                        # Full README (default)
/readme --sections "installation,usage"        # Partial update
/readme --sections "installation,usage,config" # Multiple sections
```

## Workflow

1. **Load guidance** — read `workflows/readme-create-update.md`
2. **Explore codebase** — detect project type, deployment platform, existing README, key info
3. **Generate/update** — follow workflow section order; preserve structure for partial updates
4. **Confirm changes** — present diff and ask before writing (interactive only)

## Section Mapping

| Argument | Sections Updated |
|----------|-----------------|
| `installation` | Installation, Prerequisites, Quick Start |
| `usage` | Usage, Commands, Examples, API |
| `config` | Configuration, Environment Variables |
| `architecture` | Architecture, Project Structure |
| `troubleshooting` | Troubleshooting |
| `deployment` | Deployment, Production Setup |
| `badges` | Badge section only |
| `all` | Full regeneration (same as no flag) |

**Dynamic counts (aidevops repo):** `readme-helper.sh check|update|update --apply`

## Related

- `workflows/readme-create-update.md` — full workflow
- `workflows/changelog.md` — changelog updates
- `workflows/wiki-update.md` — wiki documentation
- `scripts/readme-helper.sh` — dynamic count management
