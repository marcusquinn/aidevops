# Agent Sources (Private Repos)

Use agent sources when agents should stay in a private Git repo but remain available framework-wide. Sync copies them into `~/.aidevops/agents/custom/<source-name>/`, so they follow `custom/` tier rules: survive framework updates, are never overwritten by `setup.sh`, and auto-sync during `aidevops update` and `./setup.sh` after `deploy_aidevops_agents`.

## Lifecycle

1. Keep private agents under `.agents/` in a private Git repo.
2. Register the repo with `aidevops sources add <path>`.
3. Run `aidevops update` or `aidevops sources sync`.
4. Synced files land in `~/.aidevops/agents/custom/<source-name>/`.
5. `mode: primary` docs symlink into `~/.aidevops/agents/`, and `.md` files with `agent:` frontmatter symlink into `~/.config/opencode/command/`.

## CLI

```bash
aidevops sources add ~/Git/my-private-agents                  # Add local repo
aidevops sources add-remote git@github.com:user/agents.git    # Clone + add
aidevops sources list                                         # List sources
aidevops sources status                                       # Path, agent count, git state
aidevops sources sync                                         # Pull, rsync, symlink
aidevops sources remove my-private-agents                     # Remove (keeps files on disk)
```

## File Classification

| Frontmatter | Classification | Sync behavior |
|-------------|----------------|---------------|
| `mode: primary` | Primary agent | Sync + symlink to `~/.aidevops/agents/` root |
| `mode: subagent` | Subagent doc | Sync only |
| `agent: <Name>` | Slash command | Sync + symlink to `~/.config/opencode/command/` |
| none / other | Regular file | Sync only |

- The main agent doc is the file whose name matches its directory, for example `my-agent/my-agent.md`; `mode:` decides whether it is primary or subagent, and other `.md` files with `agent:` frontmatter become slash commands.
- Slash command conflicts append the source slug, for example `/run-pipeline-my-private-agents`. Primary agents that would overwrite core agents backed by real files, not symlinks, are skipped with a warning.

## Layout

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

Source metadata lives in `~/.aidevops/agents/configs/agent-sources.json`:

| Field | Type | Meaning |
|-------|------|---------|
| `name` | string | Directory name used for the deploy subdirectory |
| `local_path` | string | Absolute path to the local repo |
| `remote_url` | string | Git remote URL, if detected |
| `added_at` | string | ISO timestamp when the source was added |
| `last_synced` | string | ISO timestamp of the last sync |
| `agent_count` | number | Agent count from the last sync |

## Agent Sources vs Plugins

| Feature | Agent Sources | Plugins |
|---------|---------------|---------|
| Config | `agent-sources.json` | `.aidevops.json` per project |
| Deploy target | `custom/<source-name>/` | `<namespace>/` at top level |
| Scope | Global | Per-project |
| Use case | Private agent repos | Third-party extensions |
| Primary agents | Yes | No |
| Slash commands | Yes | No |
| Sync trigger | `aidevops update` / `sources sync` | `aidevops plugin update` |

## Creating a Private Agent Repo

1. Create a Git repo with a `.agents/` directory.
2. Add an agent subdirectory with `<name>.md`; use `mode: primary` if it should auto-discover.
3. Add slash commands as `.md` files with `agent: <Name>` frontmatter and any helper `.sh` scripts needed for CLI automation.
4. Follow `tools/build-agent/build-agent.md`.
5. Register the repo with `aidevops sources add <path>`.

### Slash Command Format

```yaml
---
description: Short description shown in command list
agent: Agent Name
---

Instructions for the AI when this command is invoked.

Arguments: $ARGUMENTS
```
