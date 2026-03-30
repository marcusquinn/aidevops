---
description: Create or update README.md for the current project
agent: Build+
mode: subagent
---

Create or update README.md for the current project.

**Arguments**: Optional `--sections "installation,usage"` for partial updates. Without arguments, generates/updates the full README.

## Usage

```bash
# Full README (default)
/readme

# Partial update
/readme --sections "installation,usage"
/readme --sections "troubleshooting"
```

**Use `--sections` when**: Adding a feature, changing install process, discovering common issue, or updating would lose custom content.

**Use full `/readme` when**: New project, significantly outdated, major restructuring, or explicit user request.

## Workflow

1. **Parse arguments** — check for `--sections` flag
2. **Load guidance** — read `workflows/readme-create-update.md`
3. **Explore codebase** — detect project type, deployment platform, existing README, key info
4. **Generate/update** — follow workflow section order; preserve structure for partial updates
5. **Confirm changes** — present diff and ask before writing

## Section Mapping

| Argument | Sections Updated |
|----------|------------------|
| `installation` | Installation, Prerequisites, Quick Start |
| `usage` | Usage, Commands, Examples, API |
| `config` | Configuration, Environment Variables |
| `architecture` | Architecture, Project Structure |
| `troubleshooting` | Troubleshooting |
| `deployment` | Deployment, Production Setup |
| `badges` | Badge section only |
| `all` | Full regeneration (same as no flag) |

Multiple sections: `--sections "installation,usage,config"`

## Examples

```bash
/readme                                          # Full README
/readme --sections "usage"                       # Added CLI commands
/readme --sections "config"                      # Changed env vars
/readme --sections "installation,deployment"    # Added Docker support
/readme --sections "troubleshooting"             # Fixed common issue
/readme --sections "all"                         # Major update
```

## Dynamic Counts (aidevops repo)

Use `~/.aidevops/agents/scripts/readme-helper.sh check|update|update --apply` to manage stale counts.

## Related

- `workflows/readme-create-update.md` - Full workflow guidance
- `workflows/changelog.md` - Changelog updates
- `workflows/wiki-update.md` - Wiki documentation
- `scripts/readme-helper.sh` - Dynamic count management
