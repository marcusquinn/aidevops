# {{PLUGIN_NAME}} Plugin

> This is an [aidevops](https://aidevops.sh) plugin. Install with:
>
> ```bash
> aidevops plugin add {{REPO_URL}} --namespace {{NAMESPACE}}
> ```

## Agents

| Agent | Purpose |
|-------|---------|
| `{{NAMESPACE}}.md` | Main agent for {{PLUGIN_NAME}} |

## Setup

1. Install the plugin: `aidevops plugin add {{REPO_URL}} --namespace {{NAMESPACE}}`
2. Configure any required credentials: `aidevops secret set {{PLUGIN_NAME_UPPER}}_API_KEY`
3. Use the agent: reference `{{NAMESPACE}}/` agents in your workflow

## Configuration

This plugin reads configuration from:

- `~/.config/aidevops/credentials.sh` (API keys)
- `.aidevops.json` in your project root (project-level settings)
