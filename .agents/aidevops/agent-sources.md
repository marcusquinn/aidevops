# Agent Sources (Private Repos)

Sync agents from private Git repositories into `~/.aidevops/agents/custom/<source-name>/`. This keeps private agents in their own repos while making them available to the framework.

## How It Works

1. A private repo contains a `.agents/` directory with agent subdirectories
2. You register the repo as a source via `aidevops sources add <path>`
3. On `aidevops update` or `aidevops sources sync`, agents are rsynced into `custom/`
4. Agents are available at `~/.aidevops/agents/custom/<source-name>/<agent>/`

## Directory Structure

```text
# Private repo (e.g., ~/Git/my-private-agents/)
my-private-agents/
├── .agents/
│   ├── agent-one/
│   │   ├── agent-one.md          # Agent documentation
│   │   └── agent-one-helper.sh   # Helper script
│   └── agent-two/
│       └── agent-two.md
├── AGENTS.md                      # Repo-level index
└── .gitignore

# After sync → deployed to:
~/.aidevops/agents/custom/
└── my-private-agents/
    ├── agent-one/
    │   ├── agent-one.md
    │   └── agent-one-helper.sh
    └── agent-two/
        └── agent-two.md
```

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

# Sync all sources (pulls latest, rsyncs agents)
aidevops sources sync

# Remove a source (keeps synced agents on disk)
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
      "remote_url": "git@github.com:user/agents.git",
      "added_at": "2026-02-27T01:00:00.000Z",
      "last_synced": "2026-02-27T01:22:51.973Z",
      "agent_count": 2
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
| Sync trigger | `aidevops update` / `sources sync` | `aidevops plugin update` |

## Creating a Private Agent Repo

1. Create a new Git repo with a `.agents/` directory
2. Add agent subdirectories (each with `<name>.md` and optional `<name>-helper.sh`)
3. Follow the agent design guide in `tools/build-agent/build-agent.md`
4. Register with `aidevops sources add <path>`

Agents in private repos follow the same conventions as `custom/` tier agents — they survive framework updates and are never overwritten by `setup.sh`.
