<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Plugin System

Third-party agent plugins extend aidevops with additional capabilities. Plugins are git repositories that deploy agents into namespaced directories, isolated from core agents.

## Schema

`~/.config/aidevops/plugins.json` is the single plugin registry and trust store:

```json
{
  "plugins": [
    {
      "name": "pro",
      "repo": "https://github.com/marcusquinn/aidevops-pro.git",
      "branch": "main",
      "namespace": "pro",
      "enabled": true,
      "trusted_commit": "0123456789abcdef0123456789abcdef01234567",
      "deployed_commit": "0123456789abcdef0123456789abcdef01234567",
      "hooks_enabled": false
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Human-readable plugin name |
| `repo` | string | yes | Git repository URL (HTTPS or SSH) |
| `branch` | string | no | Branch to track (default: `main`) |
| `namespace` | string | yes | Directory name under `~/.aidevops/agents/` |
| `enabled` | boolean | no | Whether the plugin is active (default: `true`) |
| `trusted_commit` | string | yes for deployment | Exact full Git object ID approved for deployment |
| `deployed_commit` | string | yes for loading | Exact object ID currently deployed; must equal `trusted_commit` |
| `hooks_enabled` | boolean | no | Whether explicit hook invocation is authorized (default: `false`) |

## Deployment

```text
~/.aidevops/agents/
├── custom/          # User's private agents (tier: custom)
├── draft/           # Experimental agents (tier: draft)
├── pro/             # Example plugin namespace
│   ├── AGENTS.md    # Plugin's agent definitions
│   └── ...          # Plugin files
└── ...              # Core agents (tier: shared)
```

## Namespacing Rules

- Namespace must be lowercase, alphanumeric, hyphens only
- Must NOT collide with reserved names: `custom`, `draft`, `scripts`, `tools`, `services`, `workflows`, `templates`, `memory`, `plugins`
- Plugin manifests and every declared agent, script, and hook are resolved through real paths and must remain inside the plugin namespace

## Lifecycle

```bash
# Add — validates namespace, clones repo, registers in subagent index
aidevops plugin add https://github.com/marcusquinn/aidevops-pro.git --namespace pro

# Update — stage the tracked branch tip, validate it, then trust and deploy its exact commit
aidevops plugin update           # all enabled plugins
aidevops plugin update pro       # specific plugin

# Trust/migrate — explicitly pin an existing registry entry, optionally to a known commit
aidevops plugin trust pro
aidevops plugin trust pro --commit 0123456789abcdef0123456789abcdef01234567

# Disable / Enable — disable removes deployed files, preserves config entry
aidevops plugin disable pro
aidevops plugin enable pro

# Hook authorization — does not execute a hook
aidevops plugin hooks pro enable
aidevops plugin hooks pro disable

# Remove — removes config entry and deployed files
aidevops plugin remove pro

# Create — scaffold new plugin from template [directory] [name] [namespace]
# Generates: AGENTS.md, main agent file, example subagent, scripts/
aidevops plugin init ./my-plugin my-plugin my-ns
```

Add, update, trust, enable, and setup deployment all clone into a sibling staging
directory. The staged commit and manifest are validated before activation. A
failed fetch, commit mismatch, containment check, manifest check, or registry
write leaves the previous plugin directory in place. Activation uses same-filesystem
renames and updates `deployed_commit` only after the validated tree is ready.

`aidevops update` deploys only `trusted_commit`; it never resolves a mutable
branch on its own. Existing entries without a trusted commit are skipped with a
migration command. Disabled directories are cleaned up. Namespaces are protected
during clean mode.

## Plugin Repository Structure

```text
plugin-repo/
├── plugin.json        # Plugin manifest (recommended)
├── AGENTS.md          # Plugin agent definitions (optional)
├── *.md               # Agent/subagent files
├── scripts/           # Helper scripts and lifecycle hooks (optional)
│   ├── on-init.sh     # Runs on install/update
│   ├── on-load.sh     # Runs on session load
│   └── on-unload.sh   # Runs on disable/remove
└── tools/             # Tool definitions (optional)
```

Entire repo contents deploy to `~/.aidevops/agents/<namespace>/`.

## Plugin Manifest (plugin.json)

Optional — plugins without a manifest fall back to directory scanning for agent discovery.

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "What this plugin does",
  "min_aidevops_version": "2.110.0",
  "agents": [
    {
      "file": "my-agent.md",
      "name": "my-agent",
      "description": "Agent purpose",
      "model": "sonnet"
    }
  ],
  "hooks": {
    "init": "scripts/on-init.sh",
    "load": "scripts/on-load.sh",
    "unload": "scripts/on-unload.sh"
  },
  "scripts": ["scripts/my-helper.sh"],
  "dependencies": []
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Plugin name (matches plugins.json entry) |
| `version` | string | yes | Semver version (X.Y.Z) |
| `description` | string | no | Human-readable description |
| `min_aidevops_version` | string | no | Minimum aidevops version required |
| `agents` | array | no | Agent definitions (file, name, description, model) |
| `hooks` | object | no | Lifecycle hook scripts (init, load, unload) |
| `scripts` | array | no | Additional helper scripts |
| `dependencies` | array | no | Required external tools or plugins |

### Agent Loader

```bash
plugin-loader-helper.sh discover   # Discover all installed plugins
plugin-loader-helper.sh load pro   # Load agents from a specific plugin
plugin-loader-helper.sh validate   # Validate plugin manifest(s)
plugin-loader-helper.sh agents     # List agents provided by plugins
plugin-loader-helper.sh index      # Generate subagent-index entries
plugin-loader-helper.sh hooks pro init  # Explicitly run an authorized hook
plugin-loader-helper.sh status     # Show plugin system status
```

Loading priority: (1) `plugin.json` `agents` array if present; (2) scan directory for `.md` files with YAML frontmatter.

The shared `subagent-index.toon` discovery file is regenerated after plugin add,
update, enable, and disable actions. `subagent-index-helper.sh generate` preserves
the core `subagents` TOON block and appends `plugin-loader-helper.sh index` output
as a lightweight `plugin_agents` block, so runtimes can discover plugin namespaces
from one startup index without reading every plugin file.

## Lifecycle Hooks

Hooks are disabled by default and are never run by add, update, trust, enable,
disable, remove, setup, or agent loading. After reviewing the pinned source,
authorize hooks in `plugins.json` through `aidevops plugin hooks <name> enable`,
then invoke a named hook explicitly with `plugin-loader-helper.sh hooks <namespace>
<init|load|unload>`. Authorization and execution are separate actions.

| Hook | Intended explicit use |
|------|-----------------------|
| `init` | One-time setup, dependency checks, config creation |
| `load` | Environment setup or PATH additions |
| `unload` | Cleanup temporary files or registrations |

Environment variables available to hooks:
- `AIDEVOPS_PLUGIN_NAMESPACE` — Plugin namespace
- `AIDEVOPS_PLUGIN_DIR` — Plugin directory path
- `AIDEVOPS_AGENTS_DIR` — Root agents directory
- `AIDEVOPS_HOOK` — Current hook name (init, load, unload)

Hooks are defined in the manifest under `hooks`, or discovered by convention at
`scripts/on-{hook}.sh`. In either case, the resolved hook path must remain inside
the plugin directory.

## Security

- Plugins are trusted by exact commit in the existing `plugins.json`; review staged source before changing trust
- A plugin loads only when `trusted_commit` and `deployed_commit` are equal full object IDs
- Plugin scripts and hooks are not auto-executed; hooks require both explicit authorization and explicit invocation
- Manifest names must match the registry, and declared members may not escape through traversal or symlinks
- Plugin agents follow the same security rules as core agents (no credential exposure, pre-edit checks)

## Integration with Agent Tiers

| Tier | Location | Survives Update | Source |
|------|----------|-----------------|--------|
| Draft | `~/.aidevops/agents/draft/` | Yes | Auto-created by orchestration |
| Custom | `~/.aidevops/agents/custom/` | Yes | User-created |
| Plugin | `~/.aidevops/agents/<namespace>/` | Yes (managed separately) | Third-party git repos |
| Shared | `.agents/` in repo | Overwritten on update | Open-source distribution |

## Configuration

Plugin state and trust: `~/.config/aidevops/plugins.json` (global, auto-created
on first use). No separate plugin trust file is used. Run `aidevops plugin help`
for full CLI documentation.

## Official Plugins

| Plugin | Namespace | Repo | Description |
|--------|-----------|------|-------------|
| **aidevops-pro** | `pro` | `https://github.com/marcusquinn/aidevops-pro.git` | Premium agents: advanced deployment, monitoring, cost optimisation |
| **aidevops-anon** | `anon` | `https://github.com/marcusquinn/aidevops-anon.git` | Privacy agents: browser fingerprints, proxy rotation, identity isolation |

```bash
aidevops plugin add https://github.com/marcusquinn/aidevops-pro.git --namespace pro
aidevops plugin add https://github.com/marcusquinn/aidevops-anon.git --namespace anon
```

### aidevops-pro Agents

| Agent | Purpose |
|-------|---------|
| `pro/advanced-deployment.md` | Blue-green, canary, and rolling deployment strategies |
| `pro/monitoring.md` | Prometheus/Grafana observability stack setup |
| `pro/cost-optimisation.md` | Cloud spend analysis and right-sizing recommendations |

### aidevops-anon Agents

| Agent | Purpose |
|-------|---------|
| `anon/browser-profiles.md` | Browser fingerprint profile creation and management |
| `anon/proxy-rotation.md` | Proxy pool management and rotation strategies |
| `anon/identity-isolation.md` | Session isolation and identity separation |
