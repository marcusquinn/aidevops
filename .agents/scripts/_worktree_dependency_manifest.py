# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed parsing of dependency inventories and workspace membership."""

from pathlib import Path
import re


class Rejected(ValueError):
    """A dependency snapshot cannot safely be provisioned."""


def pnpm_inventory(lock):
    """Accept only pnpm's simple v9 packages map, not arbitrary YAML features."""
    text = lock.decode("utf-8")
    if not re.search(r"(?m)^lockfileVersion: ['\"]?9\.0['\"]?$", text):
        raise Rejected("unsupported-pnpm-lock")
    packages = {pnpm_package_key(line) for line in pnpm_package_lines(text)}
    if not packages:
        raise Rejected("missing-pnpm-inventory")
    return packages


def pnpm_package_lines(text):
    section = False
    for line in text.splitlines():
        if line == "packages:":
            section = True
            continue
        if not section:
            continue
        if line and not line.startswith(" "):
            return
        if line.startswith("  ") and not line.startswith("   "):
            yield line


def pnpm_package_key(line):
    match = re.fullmatch(r"  ['\"]?(@?[a-zA-Z0-9_./-]+@[0-9][a-zA-Z0-9.+_-]*)['\"]?:", line)
    if not match:
        raise Rejected("unsupported-pnpm-package-key")
    return match[1]


def workspace_pattern(line):
    match = re.fullmatch(r"\s+-\s+(['\"]?)(!?[a-zA-Z0-9_./*?@-]+)\1\s*(?:#.*)?", line)
    if not match:
        raise Rejected("unsupported-workspace-pattern")
    pattern = match[2]
    if pattern.lstrip("!").startswith("/") or ".." in Path(pattern).parts:
        raise Rejected("invalid-workspace-pattern")
    return pattern


def workspace_patterns(config):
    """Parse only the supported YAML packages block, not unrelated settings."""
    patterns = []
    section = False
    for line in config.decode("utf-8").splitlines():
        if line == "packages:":
            section = True
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if section and not line.startswith(" "):
            section = False
        if section:
            patterns.append(workspace_pattern(line))
    if not patterns:
        raise Rejected("unsupported-workspace-pattern")
    return patterns


def workspace_members(worktree, patterns):
    """Expand inclusion and exclusion globs without admitting dependency trees."""
    members = {Path(".")}
    excluded = set()
    for pattern in patterns:
        for path in worktree.glob(pattern.lstrip("!")):
            relative = path.relative_to(worktree)
            if "node_modules" in relative.parts or ".git" in relative.parts:
                continue
            if (path / "package.json").is_file():
                (excluded if pattern.startswith("!") else members).add(relative)
    return members - excluded


def required_dependencies(manifest):
    required = set(manifest.get("dependencies", {})) | set(manifest.get("devDependencies", {}))
    required -= set(manifest.get("optionalDependencies", {}))
    if any(not re.fullmatch(r"(?:@[a-zA-Z0-9_.-]+/)?[a-zA-Z0-9_.-]+", key)
           or key in {".", ".."} for key in required):
        raise Rejected("invalid-dependency-name")
    return required
