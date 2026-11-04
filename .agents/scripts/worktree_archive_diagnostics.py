#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded archive-failure causes that never release paths, OIDs or raw stderr."""

import errno
import re
import subprocess

EVIDENCE_UNAVAILABLE = "producer:evidence-unavailable"

# Ordered patterns keep resource failures ahead of missing-object fallbacks.
STDERR_CATEGORIES = (
    (rb'out of memory|malloc failed|cannot allocate memory', 'allocation-failed'),
    (rb'no space left on device', 'storage-full'),
    (rb'permission denied', 'permission-denied'),
    (rb'unable to create thread|cannot create thread', 'thread-failed'),
    (rb'missing blob|missing tree|missing commit|missing object|'
     rb'bad object|bad tree object|bad commit object', 'missing-object'),
    (rb'not our ref', 'object-unavailable-or-denied'),
    (rb'(?:unable to read|could not read) (?:sha1 file )?[0-9a-f]{40,64}\b', 'missing-object'),
    (rb'did not send all necessary objects', 'transfer-failed'),
)

# GH#36564: fixed archive-helper refusals that are safe to name. The helper's
# insufficient-capacity line carries only integers, so it is passed through.
HELPER_CAUSES = (
    ("Error: worktree changed during archive capture: ", "source-changed-during-capture"),
    ("Error: worktree fingerprint unavailable", "fingerprint-unavailable"),
    ("Error: cannot resolve base SHA", "base-unresolved"),
    ("Error: archive capacity unavailable", "capacity-unavailable"),
)
CAPACITY_REFUSAL = re.compile(
    r"Error: (producer:insufficient-capacity; estimate=[0-9]+; reserve=[0-9]+; free=[0-9]+; "
    r"no archive written; source retained)")


def as_bytes(stderr):
    """Return lowercase stderr bytes, or empty bytes for absent/unknown input."""
    if isinstance(stderr, str):
        stderr = stderr.encode('utf-8', errors='replace')
    return stderr.lower() if isinstance(stderr, bytes) else b''


def stderr_category(stderr):
    """Map captured stderr to one fixed category; never return raw text."""
    text = as_bytes(stderr)
    return next((category for pattern, category in STDERR_CATEGORIES
                 if re.search(pattern, text)), 'unclassified')


def stderr_lines(stderr):
    """Split captured stderr into text lines for exact marker matching."""
    if isinstance(stderr, bytes):
        stderr = stderr.decode("utf-8", errors="replace")
    return stderr.rstrip().splitlines() if isinstance(stderr, str) else []


def process_reason(error):
    """Classify a failed subprocess by fixed helper marker or stderr category."""
    lines = stderr_lines(error.stderr)
    capacity = next(filter(None, map(CAPACITY_REFUSAL.fullmatch, reversed(lines))), None)
    if capacity:
        return capacity.group(1)
    cause = next((category for line in lines for marker, category in HELPER_CAUSES
                  if line.startswith(marker)), None) or "stderr/" + stderr_category(error.stderr)
    code = error.returncode
    if not isinstance(code, int) or not -255 <= code <= 255:
        code = "unknown"
    return f"{EVIDENCE_UNAVAILABLE}; cause={cause}; exit={code}"


def unavailable_reason(error):
    """Name the failure class without releasing paths, OIDs or raw stderr (GH#36564)."""
    if isinstance(error, subprocess.CalledProcessError):
        return process_reason(error)
    if isinstance(error, OSError):
        return f"{EVIDENCE_UNAVAILABLE}; cause=os-error/{errno.errorcode.get(error.errno, 'unknown')}"
    return f"{EVIDENCE_UNAVAILABLE}; cause=exception/{type(error).__name__}"
