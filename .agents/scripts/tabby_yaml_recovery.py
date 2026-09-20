#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Narrow recovery for YAML corrupted by the legacy Tabby profile inserter."""

from __future__ import annotations

import re

import yaml

from tabby_yaml_helpers import load_yaml_simple, save_yaml


def repair_legacy_inline_empty_profiles(content: str) -> tuple[str, bool]:
    """Normalize ``profiles: []`` only when legacy list items follow it."""
    lines = content.splitlines(keepends=True)
    for index, line in enumerate(lines):
        body = line.rstrip("\r\n")
        ending = line[len(body) :]
        match = re.fullmatch(r"profiles:\s*\[\]\s*(#.*)?", body)
        if not match:
            continue
        next_content = next(
            (
                candidate.rstrip("\r\n")
                for candidate in lines[index + 1 :]
                if candidate.strip() and not candidate.lstrip().startswith("#")
            ),
            "",
        )
        if not re.match(r"^  -(?:\s|$)", next_content):
            return content, False
        comment = match.group(1)
        lines[index] = f"profiles:{f' {comment}' if comment else ''}{ending}"
        return "".join(lines), True
    return content, False


def load_yaml_for_sync(path: str) -> tuple[str, bool]:
    """Load config, repairing only the known legacy inline-list corruption."""
    try:
        return load_yaml_simple(path), False
    except yaml.YAMLError:
        with open(path, "r") as handle:
            content = handle.read()
        repaired, changed = repair_legacy_inline_empty_profiles(content)
        if not changed:
            raise
        save_yaml(path, repaired)
        return repaired, True
