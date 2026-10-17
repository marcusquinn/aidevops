"""Outscraper MCP registration and launch-time credential migration."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import os

# outscraper-mcp-server 0.1.2 imports mcp.server.fastmcp, removed in mcp 2.x,
# without constraining mcp (GH#34620). Drop the pin once upstream supports 2.x.
OUTSCRAPER_UV_RUN = "uv tool run --with 'mcp<2' outscraper-mcp-server"
LEGACY_OUTSCRAPER_UV_RUN = "uv tool run outscraper-mcp-server"


def _is_generated_outscraper_command(command):
    """Recognize previously generated binary and pinned/unpinned bash launchers."""
    if not isinstance(command, list):
        return False
    if len(command) == 1 and isinstance(command[0], str):
        return os.path.basename(command[0]) == 'outscraper-mcp-server'
    if len(command) != 3:
        return False
    if command[:2] != ["bash", "-c"]:
        return False
    script = command[2]
    suffixes = (" " + LEGACY_OUTSCRAPER_UV_RUN, " " + OUTSCRAPER_UV_RUN)
    return isinstance(script, str) and script.endswith(suffixes)


def _credential_environments(entry):
    """Return only valid environment mappings, retaining their config fields."""
    return {field: entry[field] for field in ('env', 'environment')
            if isinstance(entry.get(field), dict)}


def _migrate_outscraper_entry(entry, launcher):
    """Replace generated or inline-credential launchers without changing custom ones."""
    environments = _credential_environments(entry)
    has_key = any('OUTSCRAPER_API_KEY' in env for env in environments.values())
    if not (has_key or _is_generated_outscraper_command(entry.get('command'))):
        return
    entry['command'] = launcher
    for field, environment in environments.items():
        environment.pop('OUTSCRAPER_API_KEY', None)
        if not environment:
            del entry[field]


def register_outscraper(config):
    """Register outscraper MCP (business intelligence)."""
    launcher = ["bash", "-c",
                'source "$HOME/.aidevops/agents/scripts/outscraper-credentials.sh" && '
                'outscraper_load_credentials && exec ' + OUTSCRAPER_UV_RUN]
    if 'outscraper' not in config['mcp']:
        config['mcp']['outscraper'] = {
            "type": "local",
            "command": launcher,
            "enabled": False
        }
        print("  Added outscraper MCP (lazy load - @outscraper subagent only)")
    elif isinstance(config['mcp']['outscraper'], dict):
        _migrate_outscraper_entry(config['mcp']['outscraper'], launcher)
    if 'outscraper_*' not in config['tools']:
        config['tools']['outscraper_*'] = False
