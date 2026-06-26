#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Core primitives for the local aidevops Vault helper."""

from __future__ import annotations

import base64
import getpass
import json
import os
import secrets
import sys
import time
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

SCHEMA_VERSION = 1
KDF_NAME = "scrypt"
AEAD_NAME = "AES-256-GCM"
KEY_LEN = 32
NONCE_LEN = 12
DEFAULT_SCRYPT = {"n": 2**15, "r": 8, "p": 1, "length": KEY_LEN}
STATE_UNINITIALIZED = "uninitialized"
STATE_LOCKED = "locked"
STATE_UNLOCKED = "unlocked"
STATE_CORRUPTED = "corrupted"


class VaultError(Exception):
    """Expected Vault failure with a stable error code."""

    def __init__(self, code: str, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


def b64e(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64d(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode((data + pad).encode("ascii"))


def default_vault_dir() -> Path:
    configured = os.environ.get("AIDEVOPS_VAULT_DIR")
    if configured:
        return Path(configured).expanduser()
    config_home = os.environ.get("XDG_CONFIG_HOME")
    if config_home:
        return Path(config_home) / "aidevops" / "vault"
    return Path.home() / ".config" / "aidevops" / "vault"


def runtime_dir(vault_dir: Path) -> Path:
    configured = os.environ.get("AIDEVOPS_VAULT_RUNTIME_DIR")
    if configured:
        return Path(configured).expanduser()
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        import hashlib

        digest = hashlib.sha256(str(vault_dir).encode("utf-8")).hexdigest()[:16]
        return Path(runtime) / "aidevops-vault" / digest
    return vault_dir / ".runtime"


def metadata_path(vault_dir: Path) -> Path:
    return vault_dir / "vault.json"


def store_path(vault_dir: Path) -> Path:
    return vault_dir / "vault-store.json"


def audit_path(vault_dir: Path) -> Path:
    return vault_dir / "audit.log"


def socket_path(vault_dir: Path) -> Path:
    return runtime_dir(vault_dir) / "broker.sock"


def pid_path(vault_dir: Path) -> Path:
    return runtime_dir(vault_dir) / "broker.pid"


def ensure_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def write_private_json(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError as exc:
        raise VaultError("VAULT_UNINITIALIZED", "Vault metadata is missing", 2) from exc
    except json.JSONDecodeError as exc:
        raise VaultError("VAULT_METADATA_CORRUPTED", "Vault metadata is corrupted", 3) from exc
    if not isinstance(data, dict):
        raise VaultError("VAULT_METADATA_CORRUPTED", "Vault metadata has invalid shape", 3)
    return data


def append_audit(vault_dir: Path, event: str, ok: bool, detail: str = "") -> None:
    ensure_private_dir(vault_dir)
    record = {"ts": int(time.time()), "event": event, "ok": ok, "detail": detail[:120]}
    path = audit_path(vault_dir)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
    os.chmod(path, 0o600)


def derive_kek(passphrase: str, salt: bytes, params: dict[str, Any]) -> bytes:
    kdf = Scrypt(
        salt=salt,
        length=int(params.get("length", KEY_LEN)),
        n=int(params.get("n", DEFAULT_SCRYPT["n"])),
        r=int(params.get("r", DEFAULT_SCRYPT["r"])),
        p=int(params.get("p", DEFAULT_SCRYPT["p"])),
    )
    return kdf.derive(passphrase.encode("utf-8"))


def encrypt_json(key: bytes, payload: dict[str, Any], aad: bytes) -> dict[str, str]:
    nonce = secrets.token_bytes(NONCE_LEN)
    plaintext = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, aad)
    return {"aead": AEAD_NAME, "nonce": b64e(nonce), "ciphertext": b64e(ciphertext)}


def decrypt_json(key: bytes, envelope: dict[str, Any], aad: bytes) -> dict[str, Any]:
    if envelope.get("aead") != AEAD_NAME:
        raise VaultError("VAULT_METADATA_CORRUPTED", "Unsupported AEAD in Vault envelope", 3)
    try:
        plaintext = AESGCM(key).decrypt(b64d(str(envelope["nonce"])), b64d(str(envelope["ciphertext"])), aad)
        data = json.loads(plaintext.decode("utf-8"))
    except (KeyError, ValueError, InvalidTag) as exc:
        raise VaultError("VAULT_DECRYPT_FAILED", "Vault decrypt failed", 4) from exc
    if not isinstance(data, dict):
        raise VaultError("VAULT_METADATA_CORRUPTED", "Vault payload has invalid shape", 3)
    return data


def prompt_passphrase(confirm: bool = False) -> str:
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise VaultError("VAULT_TTY_REQUIRED", "Vault passphrase entry requires a local TTY", 5)
    first = getpass.getpass("Vault passphrase: ", stream=sys.stderr)
    if not first:
        raise VaultError("VAULT_PASSPHRASE_EMPTY", "Vault passphrase cannot be empty", 5)
    if confirm:
        second = getpass.getpass("Confirm Vault passphrase: ", stream=sys.stderr)
        if not secrets.compare_digest(first, second):
            raise VaultError("VAULT_PASSPHRASE_MISMATCH", "Vault passphrases did not match", 5)
    return first


def validate_metadata(meta: dict[str, Any]) -> None:
    if meta.get("schema_version") != SCHEMA_VERSION:
        raise VaultError("VAULT_METADATA_CORRUPTED", "Unsupported Vault metadata schema", 3)
    if meta.get("kdf", {}).get("name") != KDF_NAME:
        raise VaultError("VAULT_METADATA_CORRUPTED", "Unsupported Vault KDF", 3)
    if "salt" not in meta.get("kdf", {}) or "wrapped_root_key" not in meta:
        raise VaultError("VAULT_METADATA_CORRUPTED", "Vault metadata is incomplete", 3)


def unwrap_root_key(meta: dict[str, Any], passphrase: str) -> bytes:
    validate_metadata(meta)
    kdf_meta = meta["kdf"]
    kek = derive_kek(passphrase, b64d(str(kdf_meta["salt"])), dict(kdf_meta.get("params", {})))
    try:
        payload = decrypt_json(kek, dict(meta["wrapped_root_key"]), b"aidevops-vault-root-key")
        root = b64d(str(payload["root_key"]))
    except (KeyError, VaultError) as exc:
        raise VaultError("VAULT_WRONG_PASSPHRASE", "Vault unlock failed", 4) from exc
    if len(root) != KEY_LEN:
        raise VaultError("VAULT_METADATA_CORRUPTED", "Vault root key has invalid length", 3)
    return root


def build_metadata(root_key: bytes, passphrase: str) -> dict[str, Any]:
    salt = secrets.token_bytes(16)
    kek = derive_kek(passphrase, salt, DEFAULT_SCRYPT)
    wrapped = encrypt_json(kek, {"root_key": b64e(root_key)}, b"aidevops-vault-root-key")
    return {
        "schema_version": SCHEMA_VERSION,
        "created_at": int(time.time()),
        "kdf": {"name": KDF_NAME, "salt": b64e(salt), "params": DEFAULT_SCRYPT},
        "wrapped_root_key": wrapped,
        "broker": {"persisted_unlock_tokens": False, "transport": "local-unix-socket"},
    }
