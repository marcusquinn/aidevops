<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agent Sources (Private Repos)

Use agent sources when agents should stay in a private Git repo but remain available framework-wide.

- Sync target: `~/.aidevops/agents/custom/<source-name>/`
- Survives framework updates and is never overwritten by `setup.sh`
- Sync runs on `aidevops update`, `./setup.sh` after `deploy_aidevops_agents`, or `aidevops sources sync`
- `mode: primary` docs symlink into `~/.aidevops/agents/`
- `.md` files with `agent:` frontmatter symlink into `~/.config/opencode/command/`

## Quick Start

1. Keep private agents under `.agents/` in a private Git repo.
2. Register the repo with `aidevops sources add <path>`.
3. Run `aidevops update` or `aidevops sources sync`.
4. Synced files land in `~/.aidevops/agents/custom/<source-name>/`.

## CLI

```bash
aidevops sources add ~/Git/my-private-agents                  # Add local repo
aidevops sources add-remote git@github.com:user/agents.git    # Clone and add
aidevops sources list                                         # List sources
aidevops sources status                                       # Path, agent count, git state
aidevops sources sync                                         # Pull, rsync, symlink
aidevops sources remove my-private-agents                     # Remove source, keep files on disk
```

## File Classification

| Frontmatter | Classification | Sync behavior |
|-------------|----------------|---------------|
| `mode: primary` | Primary agent | Sync and symlink to `~/.aidevops/agents/` root |
| `mode: subagent` | Subagent doc | Sync only |
| `agent: <Name>` | Slash command | Sync and symlink to `~/.config/opencode/command/` |
| none / other | Regular file | Sync only |

- The main agent doc is the file whose name matches its directory, for example `my-agent/my-agent.md`.
- `mode:` decides whether that main doc is primary or subagent.
- Other `.md` files with `agent:` frontmatter become slash commands.
- Slash command conflicts append the source slug, for example `/run-pipeline-my-private-agents`.
- Primary agents that would overwrite core agents backed by real files, not symlinks, are skipped with a warning.

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

## Repo Checklist

1. Create a Git repo with a `.agents/` directory.
2. Add an agent subdirectory with `<name>.md`.
3. Use `mode: primary` when the agent should auto-discover in `~/.aidevops/agents/`.
4. Add slash commands as `.md` files with `agent: <Name>` frontmatter.
5. Add any helper `.sh` scripts needed for CLI automation.
6. Add `agent-pack.json` from `.agents/templates/agent-source-repo/` and keep its
   data-flow contract current.
7. Follow `tools/build-agent/build-agent.md`.

## Data-Flow Contracts

Private agent sources should include an `agent-pack.json` manifest at the repo root.
The manifest teaches agents and validators what data the pack consumes, what it
produces, where artifacts belong, and which destinations are safe.

Required top-level fields:

- `inputs[]` — expected source material. Each input declares `name`,
  `description`, `sensitivity`, and `allowed_sources`.
- `outputs[]` — produced artifacts. Each output declares `name`, `description`,
  `artifact_path`, `sensitivity`, and `allowed_destinations`.
- `artifact_paths` — named local paths for durable working outputs.
- `sensitivity` — the default tier and supported tier list.

Every output must have its own `artifact_path` and sensitivity tier. Do not rely on
a pack-level default for outputs because the destination decision is made per
artifact.

## Privacy Tiers

| Tier | Definition | Chat | Git commits | Logs | Local workspace | GitHub issue/PR text |
|------|------------|------|-------------|------|-----------------|----------------------|
| `public-safe` | Redacted, non-private output intended for broad sharing. | Yes | Yes | Yes | Yes | Yes |
| `private-local` | Private repo, client, operational, or unpublished context. | No | Private repo only when intentional | No | Yes | No |
| `secret-adjacent` | Secret locations, credential-store metadata, access patterns, or redacted security findings. | Redacted summary only | No | No | Yes | No |
| `never-export` | Secret values, tokens, private keys, recovery codes, or unredacted credential material. | No | No | No | No; use secret store | No |

When in doubt, choose the stricter tier. A `public-safe` artifact can be surfaced in
chat, GitHub issue/PR text, logs, commits, and local workspace files. All other
tiers should stay in local workspace artifacts unless the contract explicitly
allows a narrower destination.

## Output Contract Pattern

```json
{
  "name": "private_working_notes",
  "description": "Intermediate notes that may reference private source material.",
  "artifact_path": "~/.aidevops/.agent-workspace/work/<pack-name>/notes/",
  "sensitivity": "private-local",
  "allowed_destinations": ["local-workspace"]
}
```

Use `~/.aidevops/.agent-workspace/work/<pack-name>/` for private artifacts that
must survive the session. Use `~/.aidevops/.agent-workspace/tmp/session-*` for
throwaway intermediates. Never commit `secret-adjacent` or `never-export` content.

### Slash Command Format

```yaml
---
description: Short description shown in command list
agent: Agent Name
---

Instructions for the AI when this command is invoked.

Arguments: $ARGUMENTS
```

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

## Configuration

Source metadata lives in `~/.aidevops/agents/configs/agent-sources.json` with: `name`, `local_path`, `remote_url`, `added_at`, `last_synced`, and `agent_count`.
