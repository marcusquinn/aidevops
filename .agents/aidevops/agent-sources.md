# Agent Sources (Private Repos)

Sync agents from private Git repos into `~/.aidevops/agents/custom/<source-name>/`. Private agents stay in their own repos but are available framework-wide — including primary agents and slash commands.

## How It Works

1. Private repo contains `.agents/` with agent subdirectories
2. Register via `aidevops sources add <path>`
3. On `aidevops update` or `aidevops sources sync`, agents rsync into `custom/`
4. `mode: primary` agents symlink to `~/.aidevops/agents/` root for auto-discovery
5. `.md` files with `agent:` frontmatter symlink to `~/.config/opencode/command/`

## CLI

```bash
aidevops sources add ~/Git/my-private-agents        # Add local repo
aidevops sources add-remote git@github.com:user/agents.git  # Clone + add
aidevops sources list                                # List sources
aidevops sources status                              # Path, agent count, git state
aidevops sources sync                                # Pull, rsync, symlink
aidevops sources remove my-private-agents            # Remove (keeps files on disk)
```

## File Detection Rules

Each `.md` file is classified by YAML frontmatter during sync:

| Frontmatter | Classification | Action |
|-------------|---------------|--------|
| `mode: primary` | Primary agent | Symlink to `~/.aidevops/agents/` root |
| `mode: subagent` | Subagent doc | Synced only |
| `agent: <Name>` | Slash command | Symlink to `~/.config/opencode/command/` |
| (none / other) | Regular file | Synced only |

The agent's own doc (filename matching directory name, e.g., `my-agent/my-agent.md`) is identified by `mode:`. Other `.md` files with `agent:` are slash commands.

**Collisions:** Slash command name conflicts append the source slug (`/run-pipeline-my-private-agents`). Primary agents colliding with core agents (real files, not symlinks) are skipped with a warning.

## Directory Structure

```text
# Private repo
my-private-agents/.agents/my-agent/
├── my-agent.md           # mode: primary
├── data-processing.md    # mode: subagent
├── my-agent-helper.sh    # CLI tool
├── run-pipeline.md       # agent: → /run-pipeline
└── check-status.md       # agent: → /check-status

# After sync
~/.aidevops/agents/
├── my-agent.md → custom/my-private-agents/my-agent/my-agent.md
└── custom/my-private-agents/my-agent/
    ├── my-agent.md
    ├── data-processing.md
    ├── my-agent-helper.sh
    ├── run-pipeline.md
    └── check-status.md

~/.config/opencode/command/
├── run-pipeline.md → symlink
└── check-status.md → symlink
```

## Configuration

Sources tracked in `~/.aidevops/agents/configs/agent-sources.json`:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Derived from directory name (deploy subdirectory) |
| `local_path` | string | Absolute path to local repo |
| `remote_url` | string | Git remote URL (auto-detected, optional) |
| `added_at` | string | ISO timestamp when added |
| `last_synced` | string | ISO timestamp of last sync |
| `agent_count` | number | Agents synced on last run |

## Automatic Sync

Runs automatically during `aidevops update` and `./setup.sh` (both modes). Executes after `deploy_aidevops_agents` to ensure the base directory exists.

## Difference from Plugins

| Feature | Agent Sources | Plugins |
|---------|--------------|---------|
| Config | `agent-sources.json` | `.aidevops.json` per project |
| Deploy target | `custom/<source-name>/` | `<namespace>/` (top-level) |
| Scope | Global | Per-project |
| Use case | Private agent repos | Third-party extensions |
| Primary agents | Yes | No |
| Slash commands | Yes | No |
| Sync trigger | `aidevops update` / `sources sync` | `aidevops plugin update` |

## Creating a Private Agent Repo

1. Create Git repo with `.agents/` directory
2. Add agent subdirectory with `<name>.md` (`mode: primary` for auto-discovery)
3. Add slash commands as `.md` files with `agent: <Name>` frontmatter
4. Add helper scripts (`.sh`) for CLI automation
5. Follow `tools/build-agent/build-agent.md`
6. Register: `aidevops sources add <path>`

### Slash Command Format

```yaml
---
description: Short description shown in command list
agent: Agent Name
---

Instructions for the AI when this command is invoked.

Arguments: $ARGUMENTS
```

Agents in private repos follow `custom/` tier conventions — they survive framework updates and are never overwritten by `setup.sh`.
