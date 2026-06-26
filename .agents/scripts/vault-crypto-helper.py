#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""CLI entrypoint for local aidevops Vault crypto and broker operations."""

from __future__ import annotations

import argparse
import os
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

from vault_broker_lib import broker_alive, broker_request, read_store, run_broker, write_store
from vault_crypto_core import (
    KEY_LEN,
    SETUP_STATE_MIGRATION_READY,
    SETUP_STATE_RESTART_REQUIRED,
    SETUP_STATE_TEST_VERIFIED,
    SETUP_TEST_ENTRY_NAME,
    SETUP_TEST_VALUE,
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
    prompt_acknowledgement,
    prompt_passphrase,
    runtime_dir,
    setup_state,
    unwrap_root_key,
    validate_metadata,
    write_private_json,
    write_setup_state,
)


def cmd_init(args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    ensure_private_dir(vault_dir)
    path = metadata_path(vault_dir)
    if path.exists() and not args.force:
        raise VaultError("VAULT_EXISTS", "Vault is already initialized", 2)
    print("Create a Vault passphrase with at least 12 characters.", file=sys.stderr)
    print("Use a trusted password manager with backups. Aidevops cannot recover it.", file=sys.stderr)
    prompt_acknowledgement()
    root_key = secrets.token_bytes(KEY_LEN)
    metadata = build_metadata(root_key, prompt_passphrase(confirm=True, require_strong=True))
    write_private_json(path, metadata)
    write_store(vault_dir, root_key, {"entries": {SETUP_TEST_ENTRY_NAME: SETUP_TEST_VALUE}})
    write_setup_state(vault_dir, SETUP_STATE_RESTART_REQUIRED)
    append_audit(vault_dir, "init", True)
    append_audit(vault_dir, "setup-test-created", True)
    print("Vault setup test created; restart the process and run vault unlock to verify before migrating real data")
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
    _verify_setup_test_if_needed(vault_dir, root_key)
    return _start_broker(vault_dir, root_key)


def _verify_setup_test_if_needed(vault_dir: Path, root_key: bytes) -> None:
    meta = load_json(metadata_path(vault_dir))
    state = setup_state(meta)
    if state == SETUP_STATE_MIGRATION_READY:
        return
    if state != SETUP_STATE_RESTART_REQUIRED:
        raise VaultError("VAULT_SETUP_INCOMPLETE", "Vault setup restart test has not reached restart-required", 8)
    store = read_store(vault_dir, root_key)
    if store.get("entries", {}).get(SETUP_TEST_ENTRY_NAME) != SETUP_TEST_VALUE:
        append_audit(vault_dir, "setup-test-verify", False, "missing-test-record")
        raise VaultError("VAULT_SETUP_TEST_FAILED", "Vault setup test record could not be verified", 8)
    write_setup_state(vault_dir, SETUP_STATE_TEST_VERIFIED)
    write_setup_state(vault_dir, SETUP_STATE_MIGRATION_READY)
    append_audit(vault_dir, "setup-test-verify", True)


def _start_broker(vault_dir: Path, root_key: bytes) -> int:
    ensure_private_dir(runtime_dir(vault_dir))
    # The broker process is this repo-controlled helper invoked via the current
    # Python interpreter with generated key material; no user input reaches the
    # executable path. Keep the annotation for external Bandit/CodeFactor B603.
    subprocess.Popen(  # nosec B603
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
    write_private_json(metadata_path(vault_dir), build_metadata(root_key, prompt_passphrase(confirm=True, require_strong=True)))
    append_audit(vault_dir, "change-passphrase", True)
    print("Vault passphrase changed")
    return 0


def cmd_setup_state(_args: argparse.Namespace) -> int:
    vault_dir = default_vault_dir()
    path = metadata_path(vault_dir)
    if not path.exists():
        print(STATE_UNINITIALIZED)
        return 2
    print(setup_state(load_json(path)))
    return 0


def cmd_lost_passphrase(args: argparse.Namespace) -> int:
    if args.recovery_command == "archive-and-start-fresh":
        return _archive_and_start_fresh()
    print("Lost passphrase options:")
    print("1. Try again locally with the hidden prompt; do not paste passphrases into chat, env vars, or CLI args.")
    print("2. Archive encrypted Vault files intact and start fresh: vault lost-passphrase archive-and-start-fresh")
    print("3. Import from another already-unlocked trusted device when the sync/import child ships.")
    print("4. Restore an encrypted backup or recovery kit when that child ships.")
    return 0


def _archive_and_start_fresh() -> int:
    vault_dir = default_vault_dir()
    if not vault_dir.exists():
        print("Vault is already uninitialized")
        return 0
    archive_root = vault_dir / "archives"
    archive_root.mkdir(parents=True, exist_ok=True)
    os.chmod(archive_root, 0o700)
    archive_dir = archive_root / f"lost-passphrase-{int(time.time())}"
    archive_dir.mkdir(mode=0o700)
    for name in ("vault.json", "vault-store.json", "audit.log"):
        source = vault_dir / name
        if source.exists():
            shutil.move(str(source), str(archive_dir / name))
    readme = archive_dir / "README.txt"
    readme.write_text(
        "Encrypted aidevops Vault archive. No passphrase or recovery secret is stored here. "
        "Keep this directory intact; if the passphrase is later recovered, future import tooling can attempt recovery.\n",
        encoding="utf-8",
    )
    os.chmod(readme, 0o600)
    shutil.rmtree(runtime_dir(vault_dir), ignore_errors=True)
    append_audit(vault_dir, "lost-passphrase-archive", True, archive_dir.name)
    print(f"Vault encrypted files archived intact: {archive_dir.name}")
    print("Run vault init to start fresh with a new passphrase")
    return 0


def cmd_placeholder(args: argparse.Namespace) -> int:
    raise VaultError("VAULT_COMMAND_NOT_READY", f"Vault {args.command} is reserved for a later sync/import/rekey phase", 9)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vault-crypto-helper.py")
    sub = parser.add_subparsers(dest="command", required=True)
    init_p = sub.add_parser("init")
    init_p.add_argument("--force", action="store_true")
    init_p.set_defaults(func=cmd_init)
    sub.add_parser("status").set_defaults(func=cmd_status)
    sub.add_parser("setup-state").set_defaults(func=cmd_setup_state)
    sub.add_parser("unlock").set_defaults(func=cmd_unlock)
    sub.add_parser("lock").set_defaults(func=cmd_lock)
    read_p = sub.add_parser("read")
    read_p.add_argument("name")
    read_p.set_defaults(func=cmd_read)
    update_p = sub.add_parser("update")
    update_p.add_argument("name")
    update_p.set_defaults(func=cmd_update)
    sub.add_parser("change-passphrase").set_defaults(func=cmd_change_passphrase)
    lost_p = sub.add_parser("lost-passphrase")
    lost_sub = lost_p.add_subparsers(dest="recovery_command")
    lost_sub.add_parser("archive-and-start-fresh")
    lost_p.set_defaults(func=cmd_lost_passphrase)
    for reserved in ("export", "import", "rekey"):
        sub.add_parser(reserved).set_defaults(func=cmd_placeholder)
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
