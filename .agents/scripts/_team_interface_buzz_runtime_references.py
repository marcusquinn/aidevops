"""Inventory decoded harness references before Buzz runtime pruning."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import os
from pathlib import Path
import stat
from urllib.parse import unquote, urlsplit

from _team_interface_buzz_runtime_io import RuntimeError as BuzzRuntimeError, require_safe_directory_chain


def manifest_strings(value):
    """Yield decoded strings without losing Unicode or escaped path characters."""
    if isinstance(value, str):
        yield value
        path_value = unquote(urlsplit(value).path) if value.startswith("file:") else value
        path = Path(os.path.expanduser(path_value))
        if path.is_absolute():
            # Protect aliases as well as canonical manifest paths. Resolution errors
            # propagate so a symlink loop or inaccessible component refuses pruning.
            try:
                yield str(path.resolve())
            except RuntimeError as error:  # builtin: symlink loop on Python <= 3.12
                raise BuzzRuntimeError(
                    "cannot safely resolve Buzz harness reference; pruning refused"
                ) from error
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from manifest_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from manifest_strings(item)


def harness_references(app_data_dirs):
    """Read all harnesses, including installed and development macOS bundles."""
    support = require_safe_directory_chain(Path.home() / "Library" / "Application Support")
    directories = set(app_data_dirs)
    if support.exists():
        directories.update(
            entry for entry in support.iterdir() if entry.name.startswith("xyz.block.buzz.")
        )
    references = []
    for directory in directories:
        harnesses = require_safe_directory_chain(directory / "custom_harnesses")
        if not harnesses.exists():
            continue
        for manifest in harnesses.iterdir():
            if manifest.suffix != ".json":
                continue
            metadata = manifest.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 64 * 1024:
                raise BuzzRuntimeError("cannot safely read Buzz harness references; pruning refused")
            references.extend(manifest_strings(json.loads(manifest.read_text(encoding="utf-8"))))
    return references
