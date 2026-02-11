# Plugin System

Third-party agent plugins extend aidevops with additional capabilities. Plugins are git repositories that deploy agents into namespaced directories, keeping them isolated from core agents.

## Schema

Plugins are configured in `.aidevops.json` under the `plugins` array:

```json
{
  "plugins": [
    {
      "name": "pro",
      "repo": "https://github.com/marcusquinn/aidevops-pro.git",
      "branch": "main",
      "namespace": "pro",
      "enabled": true
    }
  ]
}
```

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Human-readable plugin name |
| `repo` | string | yes | Git repository URL (HTTPS or SSH) |
| `branch` | string | no | Branch to track (default: `main`) |
| `namespace` | string | yes | Directory name under `~/.aidevops/agents/` |
| `enabled` | boolean | no | Whether the plugin is active (default: `true`) |

## Deployment

Plugins deploy to `~/.aidevops/agents/<namespace>/`:

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

- Namespace must be a valid directory name (lowercase, alphanumeric, hyphens)
- Namespace must NOT collide with core directories: `custom`, `draft`, `scripts`, `tools`, `services`, `workflows`, `templates`, `memory`, `plugins`
- Each plugin gets its own isolated namespace directory
- Plugins cannot write outside their namespace directory
- Core agents are never overwritten by plugin deployment

## Lifecycle

### Add a Plugin

```bash
aidevops plugin add https://github.com/marcusquinn/aidevops-pro.git --namespace pro
```

This:

1. Validates the namespace doesn't collide with reserved names
2. Adds the plugin entry to `.aidevops.json`
3. Clones the repo to `~/.aidevops/agents/<namespace>/`
4. Registers the plugin in the subagent index

### Update Plugins

```bash
aidevops plugin update           # Update all enabled plugins
aidevops plugin update pro       # Update a specific plugin
```

Pulls the latest from the tracked branch and redeploys.

### Automatic Deployment

Running `aidevops update` automatically deploys any enabled plugins that are not yet installed. Existing plugin directories are preserved (not re-cloned). Disabled plugin directories are cleaned up. Plugin namespaces are protected during clean mode deployments.

To force a refresh of all plugins after update:

```bash
aidevops plugin update
```

### Disable / Enable

```bash
aidevops plugin disable pro      # Sets enabled: false, removes deployed files
aidevops plugin enable pro       # Sets enabled: true, redeploys
```

Disabling removes the deployed directory but preserves the config entry.

### Remove a Plugin

```bash
aidevops plugin remove pro       # Removes config entry and deployed files
```

### Create a New Plugin

```bash
aidevops plugin init ./my-plugin my-plugin my-ns
```

Arguments: `[directory] [name] [namespace]`. Scaffolds a plugin from the built-in template with placeholder substitution. The generated structure includes AGENTS.md, a main agent file, an example subagent, and a scripts directory.

## Plugin Repository Structure

A plugin repo should follow this structure:

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

The entire repo contents are deployed to `~/.aidevops/agents/<namespace>/`.

## Plugin Manifest (plugin.json)

The manifest declares a plugin's agents, hooks, scripts, and dependencies. It is optional — plugins without a manifest fall back to directory scanning for agent discovery.

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

### Manifest Fields

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

The `plugin-loader-helper.sh` script handles plugin discovery and agent loading:

```bash
# Discover all installed plugins
plugin-loader-helper.sh discover

# Load agents from a specific plugin
plugin-loader-helper.sh load pro

# Validate plugin manifest(s)
plugin-loader-helper.sh validate

# List agents provided by plugins
plugin-loader-helper.sh agents

# Generate subagent-index entries
plugin-loader-helper.sh index

# Run a lifecycle hook
plugin-loader-helper.sh hooks pro init

# Show plugin system status
plugin-loader-helper.sh status
```

Agent loading priority:
1. If `plugin.json` exists with an `agents` array, use it (explicit declaration)
2. Otherwise, scan the plugin directory for `.md` files and parse YAML frontmatter

## Lifecycle Hooks

Plugins can define shell scripts that run at specific lifecycle events:

| Hook | When | Use Case |
|------|------|----------|
| `init` | Install, update, enable | One-time setup, dependency checks, config creation |
| `load` | Session start, agent loading | Environment setup, PATH additions |
| `unload` | Disable, remove | Cleanup temp files, revoke registrations |

Hooks receive environment variables:
- `AIDEVOPS_PLUGIN_NAMESPACE` — Plugin namespace
- `AIDEVOPS_PLUGIN_DIR` — Plugin directory path
- `AIDEVOPS_AGENTS_DIR` — Root agents directory
- `AIDEVOPS_HOOK` — Current hook name (init, load, unload)

Hook scripts are defined in the manifest under `hooks`, or discovered by convention at `scripts/on-{hook}.sh`.

## Security

- Plugins are user-installed and user-trusted
- Plugin scripts are NOT auto-executed; they must be explicitly invoked
- Plugin agents follow the same security rules as core agents (no credential exposure, pre-edit checks)
- Review plugin source before installation

## Integration with Agent Tiers

Plugins occupy a distinct tier alongside existing tiers:

| Tier | Location | Survives Update | Source |
|------|----------|-----------------|--------|
| Draft | `~/.aidevops/agents/draft/` | Yes | Auto-created by orchestration |
| Custom | `~/.aidevops/agents/custom/` | Yes | User-created |
| Plugin | `~/.aidevops/agents/<namespace>/` | Yes (managed separately) | Third-party git repos |
| Shared | `.agents/` in repo | Overwritten on update | Open-source distribution |

## Configuration

Plugin state is stored in `~/.config/aidevops/plugins.json` (global, not per-project). The file is auto-created on first use. Per-project `.aidevops.json` also has a `plugins` array for project-level plugin awareness.

Run `aidevops plugin help` for full CLI documentation.

## Official Plugins

The following plugins are maintained alongside the core aidevops framework:

| Plugin | Namespace | Repo | Description |
|--------|-----------|------|-------------|
| **aidevops-pro** | `pro` | `https://github.com/marcusquinn/aidevops-pro.git` | Premium agents: advanced deployment, monitoring, cost optimisation |
| **aidevops-anon** | `anon` | `https://github.com/marcusquinn/aidevops-anon.git` | Privacy agents: browser fingerprints, proxy rotation, identity isolation |

### Quick Install

```bash
# Install pro plugin
aidevops plugin add https://github.com/marcusquinn/aidevops-pro.git --namespace pro

# Install anon plugin
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
