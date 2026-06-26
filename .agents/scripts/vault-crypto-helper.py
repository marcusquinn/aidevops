#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Local aidevops Vault crypto and broker helper.

This module intentionally keeps passphrase collection in a local TTY prompt and
keeps unlocked root keys only in a per-session Unix-domain socket broker process.
The metadata format is versioned so a future Argon2id implementation can migrate
from the current audited `cryptography` scrypt KDF without changing callers.
"""

from __future__ import annotations

import argparse
import base64
import errno
import getpass
import hashlib
import json
import os
import secrets
import signal
import socket
import stat
import subprocess
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
    record = {
        "ts": int(time.time()),
        "event": event,
        "ok": ok,
        "detail": detail[:120],
    }
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
        nonce = b64d(str(envelope["nonce"]))
        ciphertext = b64d(str(envelope["ciphertext"]))
        plaintext = AESGCM(key).decrypt(nonce, ciphertext, aad)
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


def broker_request(vault_dir: Path, request: dict[str, Any]) -> dict[str, Any]:
    sock_path = socket_path(vault_dir)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(5)
            client.connect(str(sock_path))
            client.sendall(json.dumps(request).encode("utf-8") + b"\n")
            chunks = []
            while True:
                chunk = client.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ECONNREFUSED):
            raise VaultError("VAULT_LOCKED", "Vault is locked", 6) from exc
        raise VaultError("VAULT_BROKER_ERROR", "Vault broker request failed", 6) from exc
    raw = b"".join(chunks).decode("utf-8")
    try:
        response = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise VaultError("VAULT_BROKER_ERROR", "Vault broker returned invalid response", 6) from exc
    if not isinstance(response, dict):
        raise VaultError("VAULT_BROKER_ERROR", "Vault broker returned invalid shape", 6)
    if not response.get("ok"):
        raise VaultError(str(response.get("code", "VAULT_BROKER_ERROR")), str(response.get("message", "Vault broker error")), int(response.get("exit", 6)))
    return response


def broker_alive(vault_dir: Path) -> bool:
    try:
        broker_request(vault_dir, {"op": "status"})
        return True
    except VaultError:
        return False


def read_store(vault_dir: Path, root_key: bytes) -> dict[str, Any]:
    path = store_path(vault_dir)
    if not path.exists():
        return {"entries": {}}
    envelope = load_json(path)
    payload = decrypt_json(root_key, envelope, b"aidevops-vault-store")
    if not isinstance(payload.get("entries", {}), dict):
        raise VaultError("VAULT_STORE_CORRUPTED", "Vault store has invalid shape", 3)
    return payload


def write_store(vault_dir: Path, root_key: bytes, payload: dict[str, Any]) -> None:
    write_private_json(store_path(vault_dir), encrypt_json(root_key, payload, b"aidevops-vault-store"))


def handle_broker_client(vault_dir: Path, root_key: bytes, conn: socket.socket) -> bool:
    with conn:
        raw = conn.recv(1048576)
        try:
            request = json.loads(raw.decode("utf-8"))
            op = request.get("op")
            if op == "status":
                response = {"ok": True, "state": STATE_UNLOCKED}
            elif op == "lock":
                response = {"ok": True, "state": STATE_LOCKED}
                conn.sendall(json.dumps(response).encode("utf-8"))
                return False
            elif op == "read":
                name = str(request.get("name", ""))
                store = read_store(vault_dir, root_key)
                entries = store.get("entries", {})
                if name not in entries:
                    response = {"ok": False, "code": "VAULT_ENTRY_MISSING", "message": "Vault entry is missing", "exit": 7}
                else:
                    response = {"ok": True, "value": entries[name]}
            elif op == "update":
                name = str(request.get("name", ""))
                value = str(request.get("value", ""))
                if not name:
                    response = {"ok": False, "code": "VAULT_BAD_NAME", "message": "Vault entry name is required", "exit": 2}
                else:
                    store = read_store(vault_dir, root_key)
                    entries = dict(store.get("entries", {}))
                    entries[name] = value
                    write_store(vault_dir, root_key, {"entries": entries})
                    response = {"ok": True, "updated": name}
            else:
                response = {"ok": False, "code": "VAULT_BAD_REQUEST", "message": "Unknown Vault broker operation", "exit": 2}
        except Exception as exc:  # noqa: BLE001 - broker must fail closed.
            response = {"ok": False, "code": "VAULT_BROKER_ERROR", "message": exc.__class__.__name__, "exit": 6}
        conn.sendall(json.dumps(response).encode("utf-8"))
    return True


def run_broker(vault_dir: Path, root_key_b64: str) -> int:
    root_key = b64d(root_key_b64)
    run_dir = runtime_dir(vault_dir)
    ensure_private_dir(run_dir)
    sock_path = socket_path(vault_dir)
    pid_file = pid_path(vault_dir)
    if sock_path.exists():
        sock_path.unlink()
    stop = False

    def _signal_handler(_signum: int, _frame: Any) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(sock_path))
        os.chmod(sock_path, stat.S_IRUSR | stat.S_IWUSR)
        server.listen(8)
        server.settimeout(1)
        pid_file.write_text(str(os.getpid()), encoding="utf-8")
        os.chmod(pid_file, 0o600)
        while not stop:
            try:
                conn, _addr = server.accept()
            except socket.timeout:
                continue
            if not handle_broker_client(vault_dir, root_key, conn):
                break
    try:
        sock_path.unlink()
    except FileNotFoundError:
        pass
    try:
        pid_file.unlink()
    except FileNotFoundError:
        pass
    return 0


def cmd_init(args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    ensure_private_dir(vault_dir)
    path = metadata_path(vault_dir)
    if path.exists() and not args.force:
        raise VaultError("VAULT_EXISTS", "Vault is already initialized", 2)
    passphrase = prompt_passphrase(confirm=True)
    metadata = build_metadata(secrets.token_bytes(KEY_LEN), passphrase)
    write_private_json(path, metadata)
    append_audit(vault_dir, "init", True)
    print("Vault initialized")
    return 0


def cmd_status(_args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    path = metadata_path(vault_dir)
    if not path.exists():
        print(STATE_UNINITIALIZED)
        return 2
    try:
        validate_metadata(load_json(path))
    except VaultError:
        print(STATE_CORRUPTED)
        return 3
    print(STATE_UNLOCKED if broker_alive(vault_dir) else STATE_LOCKED)
    return 0


def cmd_unlock(_args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    if broker_alive(vault_dir):
        print("Vault already unlocked")
        return 0
    meta = load_json(metadata_path(vault_dir))
    passphrase = prompt_passphrase(confirm=False)
    try:
        root_key = unwrap_root_key(meta, passphrase)
    except VaultError:
        append_audit(vault_dir, "unlock", False, "decrypt-failed")
        raise
    run_dir = runtime_dir(vault_dir)
    ensure_private_dir(run_dir)
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "broker", b64e(root_key)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.time() + 5
    while time.time() < deadline:
        if broker_alive(vault_dir):
            append_audit(vault_dir, "unlock", True)
            print("Vault unlocked")
            return 0
        time.sleep(0.05)
    append_audit(vault_dir, "unlock", False, "broker-start-timeout")
    raise VaultError("VAULT_BROKER_ERROR", "Vault broker did not start", 6)


def cmd_lock(_args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    try:
        broker_request(vault_dir, {"op": "lock"})
    except VaultError as exc:
        if exc.code == "VAULT_LOCKED":
            print("Vault locked")
            return 0
        raise
    append_audit(vault_dir, "lock", True)
    print("Vault locked")
    return 0


def cmd_read(args: argparse.Namespace) -> int:
    response = broker_request(default_vault_dir(), {"op": "read", "name": args.name})
    print(str(response.get("value", "")))
    return 0


def cmd_update(args: argparse.Namespace) -> int:
    if sys.stdin.isatty():
        raise VaultError("VAULT_STDIN_REQUIRED", "Vault update reads the value from stdin", 2)
    value = sys.stdin.read()
    broker_request(default_vault_dir(), {"op": "update", "name": args.name, "value": value})
    print("Vault entry updated")
    return 0


def cmd_change_passphrase(_args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    meta = load_json(metadata_path(vault_dir))
    old_passphrase = prompt_passphrase(confirm=False)
    root_key = unwrap_root_key(meta, old_passphrase)
    print("Enter new Vault passphrase", file=sys.stderr)
    new_passphrase = prompt_passphrase(confirm=True)
    write_private_json(metadata_path(vault_dir), build_metadata(root_key, new_passphrase))
    append_audit(vault_dir, "change-passphrase", True)
    print("Vault passphrase changed")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vault-crypto-helper.py")
    sub = parser.add_subparsers(dest="command", required=True)
    init_p = sub.add_parser("init")
    init_p.add_argument("--force", action="store_true")
    init_p.set_defaults(func=cmd_init)
    sub.add_parser("status").set_defaults(func=cmd_status)
    sub.add_parser("unlock").set_defaults(func=cmd_unlock)
    sub.add_parser("lock").set_defaults(func=cmd_lock)
    read_p = sub.add_parser("read")
    read_p.add_argument("name")
    read_p.set_defaults(func=cmd_read)
    update_p = sub.add_parser("update")
    update_p.add_argument("name")
    update_p.set_defaults(func=cmd_update)
    sub.add_parser("change-passphrase").set_defaults(func=cmd_change_passphrase)
    broker_p = sub.add_parser("broker")
    broker_p.add_argument("root_key_b64")
    broker_p.set_defaults(func=lambda args: run_broker(default_vault_dir(), args.root_key_b64))
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except VaultError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
