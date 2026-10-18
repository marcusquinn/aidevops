#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline private-key encryption inspection. Never prints, copies or executes key material.

`ssh-keygen -y` refuses group/world-readable keys, which would hide exactly the
riskiest passphrase-less keys, so the container format is inspected directly.
"""
import base64
import os
import re
import stat
import struct

MAX_KEY_BYTES = 64 * 1024
# -{5} keeps literal PEM armour out of this source so secret scanners stay quiet.
OPENSSH = re.compile(r'-{5}BEGIN OPENSSH PRIVATE KEY-{5}(.*?)-{5}END OPENSSH PRIVATE KEY-{5}', re.DOTALL)
PEM_ENCRYPTED = re.compile(r'-{5}BEGIN ENCRYPTED PRIVATE KEY-{5}|Proc-Type: 4,ENCRYPTED')
PEM_PLAIN = re.compile(r'-{5}BEGIN (?:RSA |DSA |EC )?PRIVATE KEY-{5}')
MAGIC = b'openssh-key-v1\0'
UNREADABLE = (OSError, ValueError, struct.error)


def read_key(path):
    # O_NONBLOCK keeps FIFOs from hanging; the read itself is bounded, not just fstat.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('not a regular file')
        data = source.read(MAX_KEY_BYTES + 1)
    if len(data) > MAX_KEY_BYTES:
        raise ValueError('oversize key')
    return data.decode('ascii')


def strings(blob, offset, count):
    """Read `count` SSH wire-format strings starting at offset."""
    values = []
    for _ in range(count):
        (length,) = struct.unpack_from('>I', blob, offset)
        start = offset + 4
        offset = start + length
        if offset > len(blob):
            raise ValueError('truncated key')
        values.append(blob[start:offset])
    return values, offset


def openssh_state(body):
    blob = base64.b64decode(''.join(body.split()), validate=True)
    if not blob.startswith(MAGIC):
        raise ValueError('not openssh-key-v1')
    (cipher, _kdf, _options), offset = strings(blob, len(MAGIC), 3)
    (public,), _ = strings(blob, offset + 4, 1)  # skip the key count
    (key_type,), _ = strings(public, 0, 1)
    return cipher == b'none', key_type.startswith(b'sk-')


def key_state(path):
    """Return (unencrypted, hardware_backed), or None for an unrecognised format."""
    text = read_key(path)
    match = OPENSSH.search(text)
    if match:
        return openssh_state(match[1])
    if PEM_ENCRYPTED.search(text):
        return False, False
    if PEM_PLAIN.search(text):
        return True, False
    return None
