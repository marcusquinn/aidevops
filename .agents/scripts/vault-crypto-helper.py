#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""CLI entrypoint for local aidevops Vault crypto and broker operations."""

from __future__ import annotations

import argparse
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path

from vault_broker_lib import broker_alive, broker_request, run_broker
from vault_crypto_core import (
    KEY_LEN,
    STATE_CORRUPTED,
    STATE_LOCKED,
    STATE_UNINITIALIZED,
    STATE_UNLOCKED,
    VaultError,
    append_audit,
    b64e,
    build_metadata,
    default_vault_dir,
    ensure_private_dir,
    load_json,
    metadata_path,
    prompt_passphrase,
    runtime_dir,
    unwrap_root_key,
    validate_metadata,
    write_private_json,
)


def cmd_init(args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    ensure_private_dir(vault_dir)
    path = metadata_path(vault_dir)
    if path.exists() and not args.force:
        raise VaultError("VAULT_EXISTS", "Vault is already initialized", 2)
    metadata = build_metadata(secrets.token_bytes(KEY_LEN), prompt_passphrase(confirm=True))
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
    try:
        root_key = unwrap_root_key(meta, prompt_passphrase(confirm=False))
    except VaultError:
        append_audit(vault_dir, "unlock", False, "decrypt-failed")
        raise
    return _start_broker(vault_dir, root_key)


def _start_broker(vault_dir: Path, root_key: bytes) -> int:
    ensure_private_dir(runtime_dir(vault_dir))
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
    broker_request(default_vault_dir(), {"op": "update", "name": args.name, "value": sys.stdin.read()})
    print("Vault entry updated")
    return 0


def cmd_change_passphrase(_args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    meta = load_json(metadata_path(vault_dir))
    root_key = unwrap_root_key(meta, prompt_passphrase(confirm=False))
    print("Enter new Vault passphrase", file=sys.stderr)
    write_private_json(metadata_path(vault_dir), build_metadata(root_key, prompt_passphrase(confirm=True)))
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
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except VaultError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
