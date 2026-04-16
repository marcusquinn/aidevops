"""Shared agent configuration constants and helpers.

Single source of truth for agent definitions used by both agent-discovery.py
and opencode-agent-discovery.py. Extracted as part of t2130 to eliminate
duplication and reduce file complexity.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import glob
import os
import sys

from discovery_utils import parse_frontmatter


# =============================================================================
# AGENT CONSTANTS — Single source of truth
# =============================================================================

# Agent display name mappings (filename -> display name)
# If not in this map, derive from filename (e.g., build-agent.md -> Build-Agent)
DISPLAY_NAMES = {
    "build-plus": "Build+",
    "seo": "SEO",
    "social-media": "Social-Media",
}

# Agent ordering (agents listed here appear first in this order, rest alphabetical)
# Note: Build+ is now the single unified coding agent (Plan+ and AI-DevOps consolidated)
AGENT_ORDER = ["Build+", "Automate"]

# Files to skip (not primary agents - includes demoted agents)
# plan-plus.md and aidevops.md are now subagents, not primary agents
# browser-extension-dev.md and mobile-app-dev.md are specialist subagents under Build+
SKIP_PRIMARY_AGENTS = {"plan-plus.md", "aidevops.md", "browser-extension-dev.md", "mobile-app-dev.md"}

# Special tool configurations per agent (by display name)
# These are MCP tools that specific agents need access to
#
# MCP On-Demand Loading Strategy:
# The following MCPs are DISABLED globally to reduce context token usage:
#   - playwriter_*: ~3K tokens - enable via @playwriter subagent
#   - augment-context-engine_*: ~1K tokens - enable via @augment-context-engine subagent
#   - gh_grep_*: ~600 tokens - replaced by @github-search subagent (uses rg/bash)
#   - google-analytics-mcp_*: ~800 tokens - enable via @google-analytics subagent
#   - context7_*: ~800 tokens - enable via @context7 subagent (library docs lookup)
#   - openapi-search_*: ~500 tokens - enabled for Build+, AI-DevOps, Research only
AGENT_TOOLS = {
    "Build+": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "todoread": True, "todowrite": True,
        "openapi-search_*": True
    },
    "Onboarding": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True
    },
    "Accounts": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "quickfile_*": True
    },
    "Social-Media": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True
    },
    "SEO": {
        "write": True, "read": True, "bash": True, "webfetch": True,
        "gsc_*": True, "ahrefs_*": True, "dataforseo_*": True
    },
    "WordPress": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "localwp_*": True
    },
    "Content": {
        "write": True, "edit": True, "read": True, "webfetch": True
    },
    "Research": {
        "read": True, "webfetch": True, "bash": True,
        "openapi-search_*": True
    },
    "Automate": {
        "bash": True, "read": True, "glob": True, "grep": True,
        "task": True, "todoread": True, "todowrite": True
    },
}

# Default tools for agents not in AGENT_TOOLS
DEFAULT_TOOLS = {
    "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
    "webfetch": True, "task": True
}

# Temperature settings (by display name, default 0.2)
AGENT_TEMPS = {
    "Build+": 0.2,
    "Automate": 0.1,
    "Accounts": 0.1,
    "Legal": 0.1,
    "Content": 0.3,
    "Marketing": 0.3,
    "Research": 0.3,
}

# Custom system prompts
# ALL primary agents use the custom prompt by default to ensure consistent identity
DEFAULT_PROMPT = "~/.aidevops/agents/prompts/build.txt"

# Agents that should NOT use the custom prompt (empty by default - all agents use it)
SKIP_CUSTOM_PROMPT = set()

# Model routing tiers (from subagent YAML frontmatter 'model:' field)
MODEL_TIERS = {
    "haiku": "anthropic/claude-haiku-4-5",
    "sonnet": "anthropic/claude-sonnet-4-6",
    "opus": "anthropic/claude-opus-4-6",
    "flash": "google/gemini-3-flash-preview",
    "pro": "google/gemini-3-pro-preview",
}

# Default model tier per agent (overridden by frontmatter 'model:' field)
AGENT_MODEL_TIERS = {}

# Files to skip (not primary agents)
SKIP_FILES = {"AGENTS.md", "README.md", "configs/SKILL-SCAN-RESULTS.md"} | SKIP_PRIMARY_AGENTS

# Built-in agent types (general, explore) don't have .md files
BUILTIN_SUBAGENTS = {"general", "explore"}


# =============================================================================
# AGENT CONFIGURATION HELPERS
# =============================================================================

def filename_to_display(filename):
    """Convert filename to display name."""
    name = filename.replace(".md", "")
    if name in DISPLAY_NAMES:
        return DISPLAY_NAMES[name]
    return "-".join(word.capitalize() for word in name.split("-"))


def display_to_filename(display_name):
    """Convert display name back to filename stem."""
    reverse_map = {value: key for key, value in DISPLAY_NAMES.items()}
    if display_name in reverse_map:
        return reverse_map[display_name]
    return display_name.lower()


def get_agent_config(display_name, filename, subagents=None, model_tier=None):
    """Generate agent configuration.

    Args:
        display_name: Agent display name
        filename: Agent markdown filename
        subagents: Optional list of allowed subagent names (from frontmatter)
        model_tier: Optional model tier from frontmatter (haiku/sonnet/opus/flash/pro)
    """
    tools = AGENT_TOOLS.get(display_name, DEFAULT_TOOLS.copy())
    temp = AGENT_TEMPS.get(display_name, 0.2)

    config = {
        "description": f"Read ~/.aidevops/agents/{filename}",
        "mode": "primary",
        "temperature": temp,
        "permission": {},
        "tools": tools
    }

    # Add custom system prompt for ALL primary agents (ensures consistent identity)
    if display_name not in SKIP_CUSTOM_PROMPT:
        prompt_file = os.path.expanduser(DEFAULT_PROMPT)
        if os.path.exists(prompt_file):
            config["prompt"] = "{file:" + DEFAULT_PROMPT + "}"

    # Add model routing (from frontmatter or defaults)
    effective_tier = model_tier or AGENT_MODEL_TIERS.get(display_name)
    if effective_tier and effective_tier in MODEL_TIERS:
        config["model"] = MODEL_TIERS[effective_tier]

    # All primary agents get external_directory permission
    config["permission"] = {"external_directory": "allow"}

    # Add subagent filtering via permission.task if subagents specified
    if subagents and isinstance(subagents, list) and len(subagents) > 0:
        task_perms = {"*": "deny"}
        for subagent in subagents:
            task_perms[subagent] = "allow"
        config["permission"]["task"] = task_perms
        print(f"    {display_name}: filtered to {len(subagents)} subagents")

    return config


def sort_key(name):
    """Sort key: ordered agents first, then alphabetical."""
    if name in AGENT_ORDER:
        return (0, AGENT_ORDER.index(name))
    return (1, name.lower())


# =============================================================================
# AGENT DISCOVERY
# =============================================================================

def discover_primary_agents(agents_dir):
    """Discover primary agents from root-level .md files.

    Returns (primary_agents, sorted_agents, subagent_filtered_count).
    """
    primary_agents = {}
    subagent_filtered_count = 0

    for filepath in glob.glob(os.path.join(agents_dir, "*.md")):
        filename = os.path.basename(filepath)
        if filename in SKIP_FILES:
            continue

        display_name = filename_to_display(filename)
        frontmatter = parse_frontmatter(filepath)
        subagents = frontmatter.get('subagents', None)
        model_tier = frontmatter.get('model', None)

        if not isinstance(subagents, (list, type(None))):
            print(f"  Warning: {display_name} has malformed subagents value "
                  f"(expected list, got {type(subagents).__name__}): {subagents}",
                  file=sys.stderr)
            subagents = None

        if subagents:
            subagent_filtered_count += 1

        primary_agents[display_name] = get_agent_config(
            display_name, filename, subagents, model_tier
        )

    sorted_agents = dict(sorted(primary_agents.items(), key=lambda x: sort_key(x[0])))
    return primary_agents, sorted_agents, subagent_filtered_count


# =============================================================================
# SUBAGENT VALIDATION
# =============================================================================

def _collect_subagent_files(agents_dir):
    """Walk agents_dir and return (all_subagent_files, all_subagent_paths) sets."""
    all_subagent_files = set()
    all_subagent_paths = set()

    for root, _, files in os.walk(agents_dir):
        rel_root = os.path.relpath(root, agents_dir)
        if rel_root == "." or "loop-state" in rel_root.split(os.sep):
            continue
        for f in files:
            if not f.endswith(".md"):
                continue
            if f in {"AGENTS.md", "README.md"} or f.endswith("-skill.md"):
                continue
            full_path = os.path.join(root, f)
            fm = parse_frontmatter(full_path)
            if fm.get("mode") != "subagent":
                continue

            stem = os.path.splitext(f)[0]
            rel_path = os.path.relpath(full_path, agents_dir)
            rel_stem = os.path.splitext(rel_path)[0].replace(os.sep, "/")
            all_subagent_files.add(stem)
            all_subagent_paths.add(rel_stem)

    return all_subagent_files, all_subagent_paths


def subagent_ref_exists(agent_name, subagent_ref, all_subagent_files, all_subagent_paths):
    """Check if a subagent reference resolves to an actual file."""
    # Exact basename match
    if subagent_ref in all_subagent_files:
        return True

    # Exact path from agents root
    if subagent_ref in all_subagent_paths:
        return True

    # Agent-local relative path
    agent_slug = display_to_filename(agent_name)
    if f"{agent_slug}/{subagent_ref}" in all_subagent_paths:
        return True

    # Folder shorthand
    if "/" in subagent_ref:
        leaf = subagent_ref.rsplit("/", 1)[1]
        if (f"{agent_slug}/{subagent_ref}/{leaf}" in all_subagent_paths
                or f"{subagent_ref}/{leaf}" in all_subagent_paths):
            return True

    return False


def validate_subagent_refs(primary_agents, agents_dir):
    """Validate subagent references against actual files. Returns list of (agent, ref) missing."""
    all_subagent_files, all_subagent_paths = _collect_subagent_files(agents_dir)
    missing_refs = []

    for display_name, agent_config in primary_agents.items():
        task_perms = agent_config.get('permission', {}).get('task', {})
        if not task_perms:
            continue
        for subagent_name in task_perms:
            if subagent_name == '*':
                continue
            if subagent_name in BUILTIN_SUBAGENTS:
                continue
            if not subagent_ref_exists(display_name, subagent_name,
                                       all_subagent_files, all_subagent_paths):
                missing_refs.append((display_name, subagent_name))

    return missing_refs


# =============================================================================
# DISABLED AGENTS — Demoted agents that are now subagents
# =============================================================================

DISABLED_AGENTS = {
    "build": {"disable": True},
    "plan": {"disable": True},
    "Plan+": {"disable": True},
    "AI-DevOps": {"disable": True},
    "Browser-Extension-Dev": {"disable": True},
    "Mobile-App-Dev": {"disable": True},
}


def apply_disabled_agents(sorted_agents):
    """Add disabled agent entries to sorted_agents dict."""
    for name, config in DISABLED_AGENTS.items():
        sorted_agents[name] = config
