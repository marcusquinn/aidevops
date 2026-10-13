# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Compatibility imports for callers using the former Pulse module name."""

from github_auth_config import (
    any_configured, entry_for, matching_entries, paths, registry, registry_lock,
    settings, update_registry,
)

__all__ = [
    "any_configured", "entry_for", "matching_entries", "paths", "registry",
    "registry_lock", "settings", "update_registry",
]
