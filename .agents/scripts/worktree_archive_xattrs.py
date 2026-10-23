#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Portable no-follow inspection of metadata requiring separate preservation."""

import ctypes
import errno
import os
import sys


def darwin_xattrs(path):
    """Use Darwin's libc ABI, including XATTR_NOFOLLOW for pathname inspection."""
    libc = ctypes.CDLL(None, use_errno=True)
    descriptor = isinstance(path, int)
    function = libc.flistxattr if descriptor else libc.listxattr
    function.argtypes = [ctypes.c_int if descriptor else ctypes.c_char_p,
                         ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    function.restype = ctypes.c_ssize_t
    target = path if descriptor else os.fsencode(path)
    options = 0 if descriptor else 0x0001  # XATTR_NOFOLLOW
    for _ in range(3):
        size = function(target, None, 0, options)
        if size < 0:
            raise OSError(ctypes.get_errno(), "listxattr failed")
        if size == 0:
            return []
        buffer = ctypes.create_string_buffer(size)
        count = function(target, buffer, size, options)
        if count >= 0:
            return [os.fsdecode(name) for name in buffer.raw[:count].split(b"\0") if name]
        if ctypes.get_errno() != errno.ERANGE:
            raise OSError(ctypes.get_errno(), "listxattr failed")
    raise OSError(errno.ERANGE, "extended attributes changed during inspection")


def list_xattrs(path):
    """Return metadata requiring preservation; never follow a pathname symlink.

    Darwin provenance is OS bookkeeping, not restorable user data. Quarantine,
    resource forks, ACLs and all other attributes deliberately remain blocking.
    """
    try:
        if hasattr(os, "listxattr"):
            attributes = (os.listxattr(path) if isinstance(path, int)
                          else os.listxattr(path, follow_symlinks=False))
        elif sys.platform == "darwin":
            attributes = darwin_xattrs(path)
        else:
            raise ValueError("filesystem metadata inspection unavailable")
    except (OSError, AttributeError, NotImplementedError) as error:
        raise ValueError("filesystem metadata inspection unavailable") from error
    return [name for name in attributes
            if not (sys.platform == "darwin" and name == "com.apple.provenance")]
