# Agent Sources (Private Repos)

Sync agents from private Git repositories into `~/.aidevops/agents/custom/<source-name>/`. This keeps private agents in their own repos while making them available to the framework — including primary agents (OpenCode tabs) and slash commands.

## How It Works

1. A private repo contains a `.agents/` directory with agent subdirectories
2. You register the repo as a source via `aidevops sources add <path>`
3. On `aidevops update` or `aidevops sources sync`, agents are rsynced into `custom/`
4. **Primary agents** (`mode: primary` in frontmatter) are symlinked to `~/.aidevops/agents/` root for auto-discovery as OpenCode tabs
5. **Slash commands** (`.md` files with `agent:` in frontmatter) are symlinked to `~/.config/opencode/command/`

## Directory Structure

```text
# Private repo (e.g., ~/Git/my-private-agents/)
my-private-agents/
├── .agents/
│   └── my-agent/
│       ├── my-agent.md              # mode: primary → OpenCode tab
│       ├── data-processing.md       # mode: subagent → technical docs
│       ├── my-agent-helper.sh       # CLI tool
│       ├── run-pipeline.md          # agent: → /run-pipeline
│       └── check-status.md          # agent: → /check-status
├── AGENTS.md
└── .gitignore

# After sync → deployed to:
~/.aidevops/agents/
├── my-agent.md → symlink to custom/my-private-agents/...
└── custom/
    └── my-private-agents/
        └── my-agent/
            ├── my-agent.md
            ├── data-processing.md
            ├── my-agent-helper.sh
            ├── run-pipeline.md
            └── check-status.md

~/.config/opencode/command/
├── run-pipeline.md → symlink
└── check-status.md → symlink
```

## File Detection Rules

During sync, each `.md` file in an agent directory is classified by its YAML frontmatter:

| Frontmatter | Classification | Action |
|-------------|---------------|--------|
| `mode: primary` | Primary agent | Symlink to `~/.aidevops/agents/` root (OpenCode tab) |
| `mode: subagent` | Subagent doc | Synced only (no special handling) |
| `agent: <Name>` | Slash command | Symlink to `~/.config/opencode/command/` |
| (none / other) | Regular file | Synced only |

The agent's own doc (filename matching directory name, e.g., `my-agent/my-agent.md`) is identified by `mode:`. All other `.md` files with `agent:` are slash commands.

### Collision Handling

Slash commands use flat names by default (`/run-pipeline`). If a command name collides with an existing command from a different source, the source slug is appended automatically: `/run-pipeline-my-private-agents`.

Primary agents that collide with core agents (real files, not symlinks) are skipped with a warning.

## CLI Commands

```bash
# Add a local repo as agent source
aidevops sources add ~/Git/my-private-agents

# Clone a remote repo and add as source
aidevops sources add-remote git@github.com:user/agents.git

# List configured sources
aidevops sources list

# Show sync status (path, agent count, git state)
aidevops sources status

# Sync all sources (pulls latest, rsyncs agents, registers primary agents, deploys commands)
aidevops sources sync

# Remove a source (cleans up symlinks, keeps synced agents on disk)
aidevops sources remove my-private-agents
```

## Configuration

Sources are tracked in `~/.aidevops/agents/configs/agent-sources.json`:

```json
{
  "version": "1.0.0",
  "sources": [
    {
      "name": "my-private-agents",
      "local_path": "/Users/me/Git/my-private-agents",
      "remote_url": "",
      "added_at": "2026-01-15T10:00:00.000Z",
      "last_synced": "2026-01-15T10:05:00.000Z",
      "agent_count": 1
    }
  ]
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Derived from directory name (used as deploy subdirectory) |
| `local_path` | string | Absolute path to the local repo |
| `remote_url` | string | Git remote URL (auto-detected from origin, optional) |
| `added_at` | string | ISO timestamp when source was added |
| `last_synced` | string | ISO timestamp of last successful sync |
| `agent_count` | number | Number of agents synced on last run |

## Automatic Sync

Agent sources are synced automatically during:
- `aidevops update` (via `setup.sh` non-interactive flow)
- `./setup.sh` (both interactive and non-interactive)

The sync step runs after `deploy_aidevops_agents` to ensure the base agent directory exists.

## Difference from Plugins

| Feature | Agent Sources | Plugins |
|---------|--------------|---------|
| Config location | `agent-sources.json` | `.aidevops.json` per project |
| Deploy target | `custom/<source-name>/` | `<namespace>/` (top-level) |
| Scope | Global (all projects) | Per-project |
| Use case | Private agent repos | Third-party extensions |
| Primary agents | Yes (symlink to root) | No |
| Slash commands | Yes (symlink to command dir) | No |
| Sync trigger | `aidevops update` / `sources sync` | `aidevops plugin update` |

## Creating a Private Agent Repo

1. Create a new Git repo with a `.agents/` directory
2. Add an agent subdirectory with `<name>.md` (use `mode: primary` for an OpenCode tab)
3. Add slash commands as additional `.md` files with `agent: <Name>` frontmatter
4. Add helper scripts (`.sh`) for CLI automation
5. Follow the agent design guide in `tools/build-agent/build-agent.md`
6. Register with `aidevops sources add <path>`

### Slash Command Format

Slash commands follow the standard OpenCode command format:

```yaml
---
description: Short description shown in command list
agent: Agent Name
---

Instructions for the AI when this command is invoked.

Arguments: $ARGUMENTS
```

Agents in private repos follow the same conventions as `custom/` tier agents — they survive framework updates and are never overwritten by `setup.sh`.
