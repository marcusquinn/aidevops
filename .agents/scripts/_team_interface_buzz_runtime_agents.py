"""Sanitize deployed agent trees before immutable Buzz runtime anchoring."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from functools import partial
from pathlib import Path
import shutil


GENERATED_PLUGIN_DEPENDENCIES = Path("plugins/opencode-aidevops/node_modules")
TRANSIENT_AGENT_IGNORE = shutil.ignore_patterns(".DS_Store", "__pycache__", "*.pyc")
# setup.sh links these to stable user state outside the bundle (GH#34088).
# Anchors snapshot their contents so overrides such as custom routing apply
# and the anchor stays immutable and free of absolute links.
USER_STATE_LINKS = ("custom", "draft")


def pinned_agents_copy_ignore(source_agents, directory, names):
    """Ignore transient files, separately pinned dependencies and user-state links."""
    ignored = set(TRANSIENT_AGENT_IGNORE(directory, names))
    relative_directory = Path(directory).relative_to(source_agents)
    if relative_directory == GENERATED_PLUGIN_DEPENDENCIES.parent:
        ignored.add(GENERATED_PLUGIN_DEPENDENCIES.name)
    if relative_directory == Path("."):
        ignored.update(
            name for name in USER_STATE_LINKS
            if name in names and (Path(directory) / name).is_symlink()
        )
    return ignored


def copy_user_state_snapshots(source_agents, destination):
    """Copy linked custom/draft trees as real directories inside the anchor."""
    for name in USER_STATE_LINKS:
        link = Path(source_agents) / name
        if not link.is_symlink():
            continue
        target = link.resolve(strict=False)
        if not target.is_dir():
            continue
        shutil.copytree(target, Path(destination) / name, symlinks=True, ignore=TRANSIENT_AGENT_IGNORE)


def copy_pinned_agents(source_agents, destination):
    """Copy one agent tree without its generated external dependency link."""
    shutil.copytree(
        source_agents,
        destination,
        symlinks=True,
        ignore=partial(pinned_agents_copy_ignore, source_agents),
    )
    copy_user_state_snapshots(source_agents, destination)
