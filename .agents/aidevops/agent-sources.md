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
2. Mark the repo in `~/.config/aidevops/repos.json` with `"agent_source": true`.
3. Run `aidevops init` in the repo to seed root `AGENTS.md` and the core-style `.agents/` skeleton.
4. Register the repo with `aidevops sources add <path>`.
5. Run `aidevops update` or `aidevops sources sync`.
6. Synced files land in `~/.aidevops/agents/custom/<source-name>/`.
7. Add `.agents/agent-pack.json` when the repo exposes reusable capabilities
   that should be routed without reading every private file at startup.

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

1. Create or clone the private Git repo.
2. Add the repo to `~/.config/aidevops/repos.json` with `"agent_source": true` or compatibility form `"role": "agent-source"`.
3. Run `aidevops init`; missing root `AGENTS.md`, `.agents/AGENTS.md`, and core-style skeleton directories are seeded from `.agents/templates/agent-source-repo/`.
4. Add primary agents as root `.agents/<name>.md` files.
5. Add extended context in matching `.agents/<name>/` directories only when needed.
6. Put reusable capabilities in shared `tools/`, `services/`, `workflows/`, `reference/`, `scripts/`, `configs/`, `templates/`, `rules/`, or `tests/` directories.
7. Use `mode: primary` when the agent should auto-discover in `~/.aidevops/agents/`.
8. Add slash commands as `.md` files with `agent: <Name>` frontmatter.
9. Add helper scripts in `.agents/scripts/` and verify them with `shellcheck`.
10. Add `.agents/agent-pack.json` for private packs that should advertise
    domains, triggers, commands, helpers, secrets, and outputs compactly.
11. Keep the manifest's data-flow contract current as inputs, outputs, and
    privacy tiers change.
12. Follow `tools/build-agent/build-agent.md`.

## Init and Update Template Policy

Agent-source repos are managed as private extensions of the core framework organization model.

- **Detection:** `aidevops init` and `aidevops update` treat a repo as an agent source when its project `.aidevops.json` or managed `repos.json` entry has `"agent_source": true`; `"role": "agent-source"` is accepted for older configs.
- **Initial seed:** `aidevops init` creates root `AGENTS.md`, `.agents/AGENTS.md`, and the standard `.agents/` directory skeleton when they are missing.
- **Update propagation:** `aidevops update` traverses registered repos from `repos.json` and refreshes framework-owned template blocks in every agent-source repo.
- **Non-destructive rule:** only blocks marked with `<!-- aidevops:agent-source-template:start -->` and `<!-- aidevops:agent-source-template:end -->` are refreshed. User-authored files or files without those markers are left untouched.
- **Privacy rule:** never write private repo slugs into public TODO entries, issue bodies, PR comments, or logs. Say "a managed private agent source repo" instead.

## Agent Pack Manifest

Private repos may include `.agents/agent-pack.json`. The source sync reads this
single manifest and writes `~/.aidevops/agents/agent-source-capabilities.toon`.
`subagent-index-helper.sh generate` then appends that compact registry to
`subagent-index.toon`, preserving progressive discovery: startup reads one index
file instead of walking every private agent folder.

Use the template at `.agents/templates/agent-source-repo/agent-pack.json`.

### Fields

| Field | Purpose |
|-------|---------|
| `name`, `version`, `description` | Pack identity and compatibility signal |
| `domains` | Domain routing categories, for example `finance` or `client-ops` |
| `triggers` / `trigger_words` | Phrases that should route to this private pack |
| `primary_agents` | Public entrypoints, with `name`, `file`, `model_tier`, and `purpose` |
| `subagents` | Supporting private subagents exposed through the pack |
| `commands` | Slash commands and command docs shipped by the pack |
| `helpers` / `helper_scripts` | Deterministic scripts the pack expects agents to use |
| `required_secrets` | Secret names and storage hints; never include secret values |
| `inputs` | Expected source material, with source location and sensitivity metadata |
| `outputs` / `output_artifacts` | Generated artifact locations and contracts |
| `artifact_paths` | Named durable workspace paths for private artifacts |
| `sensitivity` / `sensitivity_tier` | Pack default sensitivity for compact capability indexing |
| `default_sensitivity`, `sensitivity_tiers` | Data-flow defaults and supported privacy tier enum |
| `upstream_candidate`, `core_candidate` | Whether the pack may graduate into shared aidevops |

Missing manifests are allowed. Invalid manifests are recorded as
`invalid-manifest` in the compact registry, and sync continues with the existing
directory scan behaviour so private agents remain available while the manifest is
fixed.

Update the manifest whenever you add a new routing domain, primary agent,
subagent, slash command, helper script, required secret, input, output artifact,
or privacy tier. Do not list credentials or private customer identifiers; use
generic secret names and generic artifact paths.

## Data-Flow Contracts

The manifest teaches agents and validators what data the pack consumes, what it
produces, where artifacts belong, and which destinations are safe.

Required data-flow fields:

- `inputs[]` — expected source material. Each input declares `name`,
  `description`, `sensitivity`, and `allowed_sources`.
- `outputs[]` — produced artifacts. Each output declares `name`, `description`,
  `artifact_path`, `sensitivity`, and `allowed_destinations`.
- `artifact_paths` — named local paths for durable working outputs.
- `default_sensitivity` and `sensitivity_tiers` — default tier and supported enum.

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
  "name": "private-working-notes",
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

Capability metadata lives in `~/.aidevops/agents/agent-source-capabilities.toon`
and is regenerated by `agent-sources-helper.sh sync`.
