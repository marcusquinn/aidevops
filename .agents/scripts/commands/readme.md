---
description: Create or update README.md for the current project
agent: Build+
mode: subagent
---

Create or update a comprehensive README.md for the current project.

**Arguments**: `--sections "installation,usage"` for partial updates. No args = full README.

## Workflow

1. **Parse args** — check for `--sections` flag (see Section Mapping below)
2. **Load workflow** — read `workflows/readme-create-update.md`
3. **Explore codebase** — detect project type (package.json, Cargo.toml, go.mod), deployment platform (Dockerfile, fly.toml, vercel.json), read existing README, gather scripts/entry points
4. **Generate/update** — new README: follow section order from workflow; `--sections`: read full README, update only specified sections, preserve structure and custom content
5. **Confirm** — present changes (section → brief description), ask: apply / show diff / modify first

**When to use `--sections`**: adding a feature, changing install process, fixing a common issue, or when full regeneration would lose custom content.

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
/readme                                    # New project or full regeneration
/readme --sections "usage"                 # Added CLI commands
/readme --sections "config"                # Changed env vars
/readme --sections "installation,deployment"  # Added Docker support
/readme --sections "troubleshooting"       # Fixed common user issue
```

## Dynamic Counts (aidevops repo)

```bash
~/.aidevops/agents/scripts/readme-helper.sh check          # Check if counts are stale
~/.aidevops/agents/scripts/readme-helper.sh update         # Preview updates
~/.aidevops/agents/scripts/readme-helper.sh update --apply # Apply updates
```

## Related

- `workflows/readme-create-update.md` — full workflow guidance
- `workflows/changelog.md` — changelog updates
- `workflows/wiki-update.md` — wiki documentation
- `scripts/readme-helper.sh` — dynamic count management
