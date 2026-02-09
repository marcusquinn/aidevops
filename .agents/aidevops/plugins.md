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
├── AGENTS.md          # Plugin agent definitions (optional)
├── *.md               # Agent/subagent files
├── scripts/           # Helper scripts (optional)
└── tools/             # Tool definitions (optional)
```

The entire repo contents are deployed to `~/.aidevops/agents/<namespace>/`.

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
