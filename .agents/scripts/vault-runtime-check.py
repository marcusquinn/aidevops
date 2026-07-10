#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Verify the exact aidevops Vault runtime and required crypto primitives."""

from __future__ import annotations

import importlib.metadata
import os
import stat
import sys
from pathlib import Path

EXPECTED = {
    "cryptography": "49.0.0",
    "cffi": "2.1.0",
    "pycparser": "3.0",
}


def check_managed_path(root: Path, marker: Path) -> int:
    try:
        paths = [root, marker, *root.rglob("*")]
        for path in paths:
            path_stat = path.lstat()
            if path_stat.st_uid != os.geteuid():
                return 1
            if stat.S_ISLNK(path_stat.st_mode):
                target = path.resolve(strict=True)
                for protected_path in [target, *target.parents]:
                    target_stat = protected_path.stat()
                    if target_stat.st_uid not in {0, os.geteuid()} or target_stat.st_mode & 0o022:
                        return 1
            elif path_stat.st_mode & 0o022:
                return 1
    except (OSError, RuntimeError):
        return 1
    return 0


def check_crypto_runtime() -> int:
    for package, expected in EXPECTED.items():
        if importlib.metadata.version(package) != expected:
            return 1

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

    key = bytes(range(32))
    nonce = bytes(range(12))
    plaintext = b"aidevops-vault-runtime-check"
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, b"runtime-check")
    if AESGCM(key).decrypt(nonce, ciphertext, b"runtime-check") != plaintext:
        return 1

    derived = Scrypt(salt=bytes(range(16)), length=32, n=2**14, r=8, p=1).derive(plaintext)
    if len(derived) != 32:
        return 1

    signing_key = Ed25519PrivateKey.generate()
    signature = signing_key.sign(plaintext)
    signing_key.public_key().verify(signature, plaintext)
    return 0


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--check-path":
        return check_managed_path(Path(sys.argv[2]), Path(sys.argv[3]))
    if len(sys.argv) != 1:
        return 1
    return check_crypto_runtime()


if __name__ == "__main__":
    raise SystemExit(main())
