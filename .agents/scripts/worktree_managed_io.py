#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded output transport for retained rootless services."""

from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import worktree_lifetime_owner as lifetime


@contextmanager
def isolated_service_io():
    """Keep retained services off tool pipes; relay regular files without waiting for EOF."""
    if all(stream.isatty() for stream in (sys.stdin, sys.stdout, sys.stderr)):
        yield {}, lambda: None, "--pty"
        return
    root = Path(os.environ.get("AIDEVOPS_TEMP_DIR") or Path.home() / ".aidevops/.agent-workspace/tmp")
    lifetime.require(not root.is_symlink(), "unsafe managed output directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    lifetime.require(root.stat().st_uid == os.getuid(), "managed output directory owner mismatch")
    with tempfile.TemporaryFile(dir=root) as out, tempfile.TemporaryFile(dir=root) as err:
        offsets = [0, 0]
        def relay():
            for index, (source, target) in enumerate(((out, sys.stdout), (err, sys.stderr))):
                # pread does not disturb the shared writer's file offset.
                data = os.pread(source.fileno(), 65536, offsets[index])
                if data:
                    offsets[index] += len(data)
                    target.buffer.write(data)
                    target.buffer.flush()
        try:
            yield {"stdin": subprocess.DEVNULL, "stdout": out, "stderr": err}, relay, "--pipe"
        finally:
            for _ in range(16):
                before = offsets.copy()
                relay()
                if offsets == before:
                    break
            if any(os.fstat(stream.fileno()).st_size > offsets[index]
                   for index, stream in enumerate((out, err))):
                print("Managed run output truncated at the bounded drain limit", file=sys.stderr)
