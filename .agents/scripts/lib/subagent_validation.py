"""Subagent reference validation for agent discovery scripts.

Extracted from agent_config.py as part of t2130 to reduce file complexity.
Validates that subagent references in agent frontmatter resolve to actual
files on disk.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import os

from discovery_utils import parse_frontmatter


# Built-in agent types (general, explore) don't have .md files
BUILTIN_SUBAGENTS = {"general", "explore"}

# Files to skip during subagent scanning
_SKIP_SUBAGENT_FILES = {"AGENTS.md", "README.md"}


def _should_skip_dir(rel_root):
    """Check if a directory should be skipped during subagent file scan."""
    return rel_root == "." or "loop-state" in rel_root.split(os.sep)


def _is_subagent_candidate(filename):
    """Check if a filename could be a subagent (basic name filter)."""
    if not filename.endswith(".md"):
        return False
    if filename in _SKIP_SUBAGENT_FILES or filename.endswith("-skill.md"):
        return False
    return True


def _register_subagent(filename, full_path, agents_dir, files_set, paths_set):
    """Register a confirmed subagent file into the tracking sets."""
    stem = os.path.splitext(filename)[0]
    rel_path = os.path.relpath(full_path, agents_dir)
    rel_stem = os.path.splitext(rel_path)[0].replace(os.sep, "/")
    files_set.add(stem)
    paths_set.add(rel_stem)


def collect_subagent_files(agents_dir):
    """Walk agents_dir and return (all_subagent_files, all_subagent_paths) sets."""
    all_subagent_files = set()
    all_subagent_paths = set()

    for root, _, files in os.walk(agents_dir):
        rel_root = os.path.relpath(root, agents_dir)
        if _should_skip_dir(rel_root):
            continue
        for f in files:
            if not _is_subagent_candidate(f):
                continue
            full_path = os.path.join(root, f)
            fm = parse_frontmatter(full_path)
            if fm.get("mode") != "subagent":
                continue
            _register_subagent(f, full_path, agents_dir, all_subagent_files, all_subagent_paths)

    return all_subagent_files, all_subagent_paths


def subagent_ref_exists(agent_name, subagent_ref, agent_slug,
                        all_subagent_files, all_subagent_paths):
    """Check if a subagent reference resolves to an actual file."""
    # Exact basename match
    if subagent_ref in all_subagent_files:
        return True

    # Exact path from agents root
    if subagent_ref in all_subagent_paths:
        return True

    # Agent-local relative path
    if f"{agent_slug}/{subagent_ref}" in all_subagent_paths:
        return True

    # Folder shorthand
    if "/" in subagent_ref:
        leaf = subagent_ref.rsplit("/", 1)[1]
        if (f"{agent_slug}/{subagent_ref}/{leaf}" in all_subagent_paths
                or f"{subagent_ref}/{leaf}" in all_subagent_paths):
            return True

    return False


def validate_subagent_refs(primary_agents, agents_dir, display_to_filename_fn=None):
    """Validate subagent references against actual files.

    Args:
        primary_agents: Dict of agent display_name -> config.
        agents_dir: Path to agents directory.
        display_to_filename_fn: Function to convert display name to filename stem.
            If None (default), imports agent_config.display_to_filename lazily.
            The lazy import avoids a module-level circular import between
            agent_config and subagent_validation (agent_config re-exports
            validate_subagent_refs for backward compatibility).

    Returns list of (agent_display_name, subagent_ref) tuples for missing refs.
    """
    if display_to_filename_fn is None:
        # Lazy import to avoid circular dependency with agent_config at module load.
        from agent_config import display_to_filename as _display_to_filename
        display_to_filename_fn = _display_to_filename

    all_subagent_files, all_subagent_paths = collect_subagent_files(agents_dir)
    missing_refs = []

    for display_name, agent_config in primary_agents.items():
        task_perms = agent_config.get('permission', {}).get('task', {})
        if not task_perms:
            continue
        agent_slug = display_to_filename_fn(display_name)
        for subagent_name in task_perms:
            if subagent_name == '*':
                continue
            if subagent_name in BUILTIN_SUBAGENTS:
                continue
            if not subagent_ref_exists(display_name, subagent_name, agent_slug,
                                       all_subagent_files, all_subagent_paths):
                missing_refs.append((display_name, subagent_name))

    return missing_refs
