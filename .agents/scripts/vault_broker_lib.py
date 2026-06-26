#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""In-memory Unix-socket broker for the local aidevops Vault."""

from __future__ import annotations

import errno
import json
import os
import signal
import socket
import stat
from pathlib import Path
from typing import Any

from vault_crypto_core import (
    STATE_LOCKED,
    STATE_UNLOCKED,
    VaultError,
    b64d,
    decrypt_json,
    ensure_private_dir,
    load_json,
    pid_path,
    runtime_dir,
    socket_path,
    store_path,
    write_private_json,
    encrypt_json,
)


def broker_request(vault_dir: Path, request: dict[str, Any]) -> dict[str, Any]:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(5)
            client.connect(str(socket_path(vault_dir)))
            client.sendall(json.dumps(request).encode("utf-8") + b"\n")
            chunks = _read_response(client)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ECONNREFUSED):
            raise VaultError("VAULT_LOCKED", "Vault is locked", 6) from exc
        raise VaultError("VAULT_BROKER_ERROR", "Vault broker request failed", 6) from exc
    return _parse_response(chunks)


def _read_response(client: socket.socket) -> bytes:
    chunks = []
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def _parse_response(raw: bytes) -> dict[str, Any]:
    try:
        response = json.loads(raw.decode("utf-8"))
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
    payload = decrypt_json(root_key, load_json(path), b"aidevops-vault-store")
    if not isinstance(payload.get("entries", {}), dict):
        raise VaultError("VAULT_STORE_CORRUPTED", "Vault store has invalid shape", 3)
    return payload


def write_store(vault_dir: Path, root_key: bytes, payload: dict[str, Any]) -> None:
    write_private_json(store_path(vault_dir), encrypt_json(root_key, payload, b"aidevops-vault-store"))


def handle_broker_client(vault_dir: Path, root_key: bytes, conn: socket.socket) -> bool:
    with conn:
        try:
            request = json.loads(conn.recv(1048576).decode("utf-8"))
            response, keep_running = _dispatch_request(vault_dir, root_key, request)
        except Exception as exc:  # noqa: BLE001 - broker must fail closed.
            response = {"ok": False, "code": "VAULT_BROKER_ERROR", "message": exc.__class__.__name__, "exit": 6}
            keep_running = True
        conn.sendall(json.dumps(response).encode("utf-8"))
    return keep_running


def _dispatch_request(vault_dir: Path, root_key: bytes, request: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    op = request.get("op")
    if op == "status":
        return {"ok": True, "state": STATE_UNLOCKED}, True
    if op == "lock":
        return {"ok": True, "state": STATE_LOCKED}, False
    if op == "read":
        return _read_entry(vault_dir, root_key, str(request.get("name", ""))), True
    if op == "update":
        return _update_entry(vault_dir, root_key, str(request.get("name", "")), str(request.get("value", ""))), True
    return {"ok": False, "code": "VAULT_BAD_REQUEST", "message": "Unknown Vault broker operation", "exit": 2}, True


def _read_entry(vault_dir: Path, root_key: bytes, name: str) -> dict[str, Any]:
    entries = read_store(vault_dir, root_key).get("entries", {})
    if name not in entries:
        return {"ok": False, "code": "VAULT_ENTRY_MISSING", "message": "Vault entry is missing", "exit": 7}
    return {"ok": True, "value": entries[name]}


def _update_entry(vault_dir: Path, root_key: bytes, name: str, value: str) -> dict[str, Any]:
    if not name:
        return {"ok": False, "code": "VAULT_BAD_NAME", "message": "Vault entry name is required", "exit": 2}
    store = read_store(vault_dir, root_key)
    entries = dict(store.get("entries", {}))
    entries[name] = value
    write_store(vault_dir, root_key, {"entries": entries})
    return {"ok": True, "updated": name}


def run_broker(vault_dir: Path, root_key_b64: str) -> int:
    root_key = b64d(root_key_b64)
    run_dir = runtime_dir(vault_dir)
    ensure_private_dir(run_dir)
    sock_file = socket_path(vault_dir)
    if sock_file.exists():
        sock_file.unlink()
    return _serve(vault_dir, root_key, sock_file)


def _serve(vault_dir: Path, root_key: bytes, sock_file: Path) -> int:
    stop = False

    def _signal_handler(_signum: int, _frame: Any) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(sock_file))
        os.chmod(sock_file, stat.S_IRUSR | stat.S_IWUSR)
        server.listen(8)
        server.settimeout(1)
        _write_pid(vault_dir)
        while not stop:
            stop = _accept_once(vault_dir, root_key, server)
    _cleanup_runtime(vault_dir, sock_file)
    return 0


def _accept_once(vault_dir: Path, root_key: bytes, server: socket.socket) -> bool:
    try:
        conn, _addr = server.accept()
    except socket.timeout:
        return False
    return not handle_broker_client(vault_dir, root_key, conn)


def _write_pid(vault_dir: Path) -> None:
    pid_file = pid_path(vault_dir)
    pid_file.write_text(str(os.getpid()), encoding="utf-8")
    os.chmod(pid_file, 0o600)


def _cleanup_runtime(vault_dir: Path, sock_file: Path) -> None:
    for path in (sock_file, pid_path(vault_dir)):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
