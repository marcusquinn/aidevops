"""Shared utilities for agent discovery scripts.

Extracted from agent-discovery.py and opencode-agent-discovery.py to eliminate
duplication. Provides atomic JSON writes and YAML frontmatter parsing.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import os
import sys
import tempfile


def atomic_json_write(path, data, indent=2, trailing_newline=False):
    """Write JSON atomically: tmp file + fsync + rename. Prevents truncation on crash."""
    dir_name = os.path.dirname(path) or '.'
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp', prefix='.atomic-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=indent)
            if trailing_newline:
                f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def parse_frontmatter(filepath):
    """Parse YAML frontmatter from markdown file.

    Minimal parser — no PyYAML dependency. Supports:
      - Simple key: value pairs (unquoted, single-line)
      - Dash-prefixed list items (single level)
    Does NOT support: quoted values containing colons, multi-line blocks,
    or nested mappings. Agent frontmatter must stay within these constraints.
    """
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        if not content.startswith('---'):
            return {}
        end_idx = content.find('---', 3)
        if end_idx == -1:
            return {}
        frontmatter = content[3:end_idx].strip()
        return _parse_frontmatter_lines(frontmatter.split('\n'))
    except (IOError, OSError, UnicodeDecodeError) as e:
        print(f"Warning: Failed to parse frontmatter for {filepath}: {e}", file=sys.stderr)
        return {}


def _parse_frontmatter_lines(lines):
    """Parse frontmatter lines into a dict. Extracted for testability."""
    result = {}
    current_key = None
    current_list = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if stripped.startswith('- ') and current_key:
            current_list.append(stripped[2:].strip())
        elif ':' in stripped and not stripped.startswith('-'):
            if current_key and current_list:
                result[current_key] = current_list
                current_list = []
            key, value = stripped.split(':', 1)
            current_key = key.strip()
            value = value.strip()
            if value:
                result[current_key] = value
                current_key = None
    if current_key and current_list:
        result[current_key] = current_list
    return result
