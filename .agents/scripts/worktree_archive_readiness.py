#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded, opaque readiness records in the existing Git-admin artifact."""

READINESS_ADMIN_FILES = {
    "aidevops/js-readiness.json", "aidevops/js-restore.json",
    "aidevops/js-readiness-entry", "aidevops/js-prepare.json",
}
MAX_READINESS_BYTES = 1024 * 1024


def read_admin_bytes(entry, name):
    """Bound readiness input before allocation; leave Git's own files unchanged."""
    if name not in READINESS_ADMIN_FILES:
        return entry.read_bytes()
    with entry.open("rb") as handle:
        content = handle.read(MAX_READINESS_BYTES + 1)
    if len(content) > MAX_READINESS_BYTES:
        raise ValueError(f"git_admin:readiness_too_large:{name}")
    return content


def validate_readiness_payload(name, value):
    """Apply the same limit to encoded records before decoding/restoration."""
    if name not in READINESS_ADMIN_FILES:
        return
    if not isinstance(value, str) or len(value) > MAX_READINESS_BYTES * 2:
        raise ValueError(f"git_admin:readiness_too_large:{name}")
