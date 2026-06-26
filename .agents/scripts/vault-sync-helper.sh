#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" || $# -eq 0 ]]; then
	cat <<'EOF'
Usage: vault-sync-helper.sh <command> [options]

Commands:
  init [vault directory option]
      Create a local sync device key file with 0600 permissions.
  export --collection NAME --namespace NAME --entry NAME --output FILE [vault directory option] [--pad-bytes N]
      Export one encrypted Vault entry as an append-only signed sync record.
  import --input FILE [vault directory option] [--revoked-devices FILE]
      Verify, decrypt, and stage one sync record in the local encrypted inbox.
  rekey
      Delegate to vault-helper.sh change-passphrase; passphrases stay in TTY prompts.

The helper never accepts passphrases in arguments or environment variables. Git,
object storage, and message relays are untrusted transports; records contain only
opaque ids, hashes, signatures, padding, and ciphertext.
EOF
	exit 0
fi

command_name="${1-}"
shift || true

case "$command_name" in
	init | export | import)
		python3 - "$command_name" "$@" <<'PY'
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import secrets
import sys
import time
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat


SCHEMA_VERSION = 1
ARG_VAULT_DIR = "--vault-dir"
ENCODING = "utf-8"
KEY_FILE = "sync-device.json"
MANIFEST_FILE = "sync-manifest.json"
INBOX_FILE = "sync-inbox.json"
NONCE_LEN = 12
FIELD_AUTHOR_DEVICE = "author_device"
FIELD_COLLECTION = "collection"
FIELD_CONTENT_HASH = "content_hash"
FIELD_DEVICE_ID = "device_id"
FIELD_DEVICE_SEQUENCES = "device_sequences"
FIELD_ENTRY = "entry"
FIELD_IMPORTED_RECORDS = "imported_records"
FIELD_LAST_SEQUENCE = "last_sequence"
FIELD_NAMESPACE_HASH = "namespace_hash"
FIELD_RECORDS = "records"
FIELD_SCHEMA_VERSION = "schema_version"
FIELD_SEQUENCE = "sequence"
FIELD_TRANSPORT_KEY = "transport_key"


class SyncError(Exception):
    def __init__(self, code: str, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


def b64e(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64d(data: str) -> bytes:
    return base64.urlsafe_b64decode((data + ("=" * (-len(data) % 4))).encode("ascii"))


def canonical(data: dict[str, Any]) -> bytes:
    return json.dumps(data, sort_keys=True, separators=(",", ":")).encode(ENCODING)


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode(ENCODING)).hexdigest()


def vault_dir_from(value: str | None) -> Path:
    if value:
        return Path(value).expanduser()
    configured = os.environ.get("AIDEVOPS_VAULT_DIR")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".config" / "aidevops" / "vault"


def private_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    payload = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode(ENCODING)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(tmp, flags, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)
    tmp.replace(path)


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding=ENCODING))
    except FileNotFoundError as exc:
        raise SyncError("VAULT_SYNC_MISSING", f"Missing file: {path.name}", 2) from exc
    except json.JSONDecodeError as exc:
        raise SyncError("VAULT_SYNC_CORRUPTED", f"Invalid JSON: {path.name}", 3) from exc
    if not isinstance(data, dict):
        raise SyncError("VAULT_SYNC_CORRUPTED", f"Invalid JSON shape: {path.name}", 3)
    return data


def key_path(vault_dir: Path) -> Path:
    return vault_dir / KEY_FILE


def load_key(vault_dir: Path) -> dict[str, Any]:
    key = load_json(key_path(vault_dir))
    if key.get(FIELD_SCHEMA_VERSION) != SCHEMA_VERSION:
        raise SyncError("VAULT_SYNC_KEY_CORRUPTED", "Unsupported sync key schema", 3)
    return key


def cmd_init(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    path = key_path(vault_dir)
    if path.exists() and not args.force:
        raise SyncError("VAULT_SYNC_KEY_EXISTS", "Vault sync device key already exists", 2)
    signing_key = Ed25519PrivateKey.generate()
    public_key = signing_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    device_id = hashlib.sha256(public_key).hexdigest()
    payload = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "created_at": int(time.time()),
        FIELD_DEVICE_ID: device_id,
        "signing_private_key": b64e(signing_key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())),
        "signing_public_key": b64e(public_key),
        FIELD_TRANSPORT_KEY: b64e(secrets.token_bytes(32)),
        FIELD_LAST_SEQUENCE: 0,
    }
    private_write_json(path, payload)
    print(f"Vault sync device initialized: {device_id[:16]}")
    return 0


def read_store_entry(vault_dir: Path, entry: str) -> dict[str, Any]:
    store = load_json(vault_dir / "vault-store.json")
    entries = store.get("entries")
    if not isinstance(entries, dict) or entry not in entries:
        raise SyncError("VAULT_SYNC_ENTRY_MISSING", "Encrypted Vault entry is missing", 7)
    value = entries[entry]
    if not isinstance(value, (dict, str)):
        raise SyncError("VAULT_SYNC_ENTRY_INVALID", "Encrypted Vault entry has invalid shape", 3)
    return {"entry_hash": sha256_text(entry), "encrypted_entry": value}


def sign_record(record: dict[str, Any], private_key_b64: str) -> str:
    signing_key = Ed25519PrivateKey.from_private_bytes(b64d(private_key_b64))
    return b64e(signing_key.sign(canonical(record)))


def verify_record(record: dict[str, Any], signature: str) -> None:
    try:
        author_public_key = b64d(str(record["author_public_key"]))
    except (KeyError, binascii.Error, ValueError) as exc:
        raise SyncError("VAULT_SYNC_BAD_SIGNATURE", "Vault sync record author public key is invalid", 4) from exc
    author_device = str(record.get(FIELD_AUTHOR_DEVICE, ""))
    if hashlib.sha256(author_public_key).hexdigest() != author_device:
        raise SyncError("VAULT_SYNC_BAD_SIGNATURE", "Vault sync record author device does not match public key", 4)
    public_key = Ed25519PublicKey.from_public_bytes(author_public_key)
    try:
        public_key.verify(b64d(signature), canonical(record))
    except (InvalidSignature, binascii.Error, ValueError) as exc:
        raise SyncError("VAULT_SYNC_BAD_SIGNATURE", "Vault sync record signature is invalid", 4) from exc


def cmd_export(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    key = load_key(vault_dir)
    sequence = int(key.get(FIELD_LAST_SEQUENCE, 0)) + 1
    entry_payload = read_store_entry(vault_dir, args.entry)
    pad_bytes = max(0, int(args.pad_bytes))
    plaintext = {FIELD_ENTRY: entry_payload, "padding": b64e(secrets.token_bytes(pad_bytes)) if pad_bytes else ""}
    nonce = secrets.token_bytes(NONCE_LEN)
    ciphertext = AESGCM(b64d(str(key[FIELD_TRANSPORT_KEY]))).encrypt(nonce, canonical(plaintext), b"aidevops-vault-sync-record")
    record_id = secrets.token_hex(32)
    record = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "record_id": record_id,
        FIELD_COLLECTION: args.collection,
        FIELD_NAMESPACE_HASH: sha256_text(args.namespace),
        FIELD_AUTHOR_DEVICE: str(key[FIELD_DEVICE_ID]),
        "author_public_key": str(key["signing_public_key"]),
        FIELD_SEQUENCE: sequence,
        "vector": {str(key[FIELD_DEVICE_ID]): sequence},
        FIELD_CONTENT_HASH: hashlib.sha256(canonical(entry_payload)).hexdigest(),
        "tombstone": False,
        "created_at": int(time.time()),
        "expires_at": int(args.expires_at) if args.expires_at else None,
        "ciphertext": {"aead": "AES-256-GCM", "nonce": b64e(nonce), "payload": b64e(ciphertext)},
    }
    envelope = {"record": record, "signature": sign_record(record, str(key["signing_private_key"]))}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_suffix(output.suffix + ".tmp")
    tmp.write_text(json.dumps(envelope, indent=2, sort_keys=True) + "\n", encoding=ENCODING)
    tmp.replace(output)
    key[FIELD_LAST_SEQUENCE] = sequence
    private_write_json(key_path(vault_dir), key)
    print(record_id)
    return 0


def load_manifest(vault_dir: Path) -> dict[str, Any]:
    path = vault_dir / MANIFEST_FILE
    if not path.exists():
        return {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_IMPORTED_RECORDS: {}, FIELD_DEVICE_SEQUENCES: {}}
    return load_json(path)


def load_revoked(path_value: str | None) -> set[str]:
    if not path_value:
        return set()
    data = load_json(Path(path_value))
    revoked = data.get("revoked_devices", [])
    if not isinstance(revoked, list):
        raise SyncError("VAULT_SYNC_REVOKED_INVALID", "Revoked device list is invalid", 3)
    return {str(item) for item in revoked}


def cmd_import(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    key = load_key(vault_dir)
    envelope = load_json(Path(args.input))
    record = envelope.get("record")
    if not isinstance(record, dict):
        raise SyncError("VAULT_SYNC_RECORD_INVALID", "Vault sync record is invalid", 3)
    signature = str(envelope.get("signature", ""))
    verify_record(record, signature)
    now = int(time.time())
    expires_at = record.get("expires_at")
    if expires_at is not None and int(expires_at) < now:
        raise SyncError("VAULT_SYNC_EXPIRED", "Vault sync record is expired", 4)
    author = str(record.get(FIELD_AUTHOR_DEVICE, ""))
    if author in load_revoked(args.revoked_devices):
        raise SyncError("VAULT_SYNC_REVOKED_DEVICE", "Vault sync record author is revoked", 4)
    manifest = load_manifest(vault_dir)
    imported = dict(manifest.get(FIELD_IMPORTED_RECORDS, {}))
    record_id = str(record.get("record_id", ""))
    if record_id in imported:
        raise SyncError("VAULT_SYNC_REPLAY", "Vault sync record was already imported", 4)
    device_sequences = dict(manifest.get(FIELD_DEVICE_SEQUENCES, {}))
    sequence = int(record.get(FIELD_SEQUENCE, 0))
    if sequence <= int(device_sequences.get(author, 0)):
        raise SyncError("VAULT_SYNC_ROLLBACK", "Vault sync sequence rolls back", 4)
    ciphertext = record.get("ciphertext", {})
    if not isinstance(ciphertext, dict):
        raise SyncError("VAULT_SYNC_RECORD_INVALID", "Vault sync record ciphertext is invalid", 3)
    try:
        plaintext = AESGCM(b64d(str(key[FIELD_TRANSPORT_KEY]))).decrypt(
            b64d(str(ciphertext["nonce"])), b64d(str(ciphertext["payload"])), b"aidevops-vault-sync-record"
        )
    except (KeyError, binascii.Error, InvalidTag, ValueError) as exc:
        raise SyncError("VAULT_SYNC_DECRYPT_FAILED", "Failed to decrypt sync record payload", 4) from exc
    try:
        payload = json.loads(plaintext.decode(ENCODING))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SyncError("VAULT_SYNC_RECORD_INVALID", "Failed to parse sync record payload", 3) from exc
    if not isinstance(payload, dict):
        raise SyncError("VAULT_SYNC_RECORD_INVALID", "Vault sync record payload is invalid", 3)
    inbox = load_json(vault_dir / INBOX_FILE) if (vault_dir / INBOX_FILE).exists() else {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_RECORDS: {}}
    records = dict(inbox.get(FIELD_RECORDS, {}))
    records[record_id] = {FIELD_COLLECTION: record.get(FIELD_COLLECTION), FIELD_NAMESPACE_HASH: record.get(FIELD_NAMESPACE_HASH), FIELD_ENTRY: payload.get(FIELD_ENTRY)}
    private_write_json(vault_dir / INBOX_FILE, {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_RECORDS: records})
    imported[record_id] = {FIELD_AUTHOR_DEVICE: author, FIELD_SEQUENCE: sequence, FIELD_CONTENT_HASH: record.get(FIELD_CONTENT_HASH), "imported_at": now}
    device_sequences[author] = sequence
    private_write_json(vault_dir / MANIFEST_FILE, {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_IMPORTED_RECORDS: imported, FIELD_DEVICE_SEQUENCES: device_sequences})
    print(record_id)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vault-sync-helper.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    init_p = sub.add_parser("init")
    init_p.add_argument(ARG_VAULT_DIR)
    init_p.add_argument("--force", action="store_true")
    init_p.set_defaults(func=cmd_init)
    export_p = sub.add_parser("export")
    export_p.add_argument(ARG_VAULT_DIR)
    export_p.add_argument("--collection", required=True)
    export_p.add_argument("--namespace", required=True)
    export_p.add_argument("--entry", required=True)
    export_p.add_argument("--output", required=True)
    export_p.add_argument("--pad-bytes", default="0")
    export_p.add_argument("--expires-at")
    export_p.set_defaults(func=cmd_export)
    import_p = sub.add_parser("import")
    import_p.add_argument(ARG_VAULT_DIR)
    import_p.add_argument("--input", required=True)
    import_p.add_argument("--revoked-devices")
    import_p.set_defaults(func=cmd_import)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args(sys.argv[1:])
    try:
        return int(args.func(args))
    except SyncError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
PY
		;;
	rekey)
		"$SCRIPT_DIR/vault-helper.sh" change-passphrase "$@"
		;;
	*)
		printf '%s\n' "[ERROR] Unknown Vault sync command: $command_name" >&2
		exit 2
		;;
esac
