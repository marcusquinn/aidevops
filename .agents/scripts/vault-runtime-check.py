#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Verify the exact aidevops Vault runtime and required crypto primitives."""

from __future__ import annotations

import importlib.metadata
import sys

EXPECTED = {
    "cryptography": "49.0.0",
    "cffi": "2.1.0",
    "pycparser": "3.0",
}


def main() -> int:
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


if __name__ == "__main__":
    raise SystemExit(main())
