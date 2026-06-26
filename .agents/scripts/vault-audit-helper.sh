#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

usage() {
	cat <<'EOF'
Usage: vault-audit-helper.sh <command> [options]

Commands:
  init [--force] [--vault-dir DIR]
      Create a local device audit key separate from Vault data/sync/control keys.
  append --actor ID --action NAME --target-collection NAME --result RESULT [options]
      Append an encrypted, signed, hash-chained Vault audit event.
  verify [--log FILE] [--receipt FILE ...]
      Verify hash-chain continuity, signatures, sequence ordering, and receipts.
      Record signatures are checked against a trusted local or explicit audit key.
  receipt --head HASH --sequence N --observer-device ID [--output FILE]
      Sign a peer receipt proving another trusted device observed a checkpoint.
  anchor --head HASH --sequence N [--output FILE]
      Emit a public-safe signed checkpoint containing hashes and sequence only.
  replicate --output-dir DIR
      Copy encrypted audit records plus public anchors/receipts to a peer/private repo staging dir.
  report [--json]
      Summarise local audit health without decrypting or printing event contents.

Full event payloads are encrypted for trusted audit readers. Public anchors expose
only schema, device id, sequence, head hash, timestamp, and signature. Passphrases,
secret values, decrypted content, and full prompt/session text are never accepted
or printed by this helper.
EOF
	return 0
}

command="${1:-help}"
case "$command" in
help | --help | -h)
	usage
	exit 0
	;;
init | append | verify | receipt | anchor | replicate | report)
	shift || true
	python3 - "$command" "$@" <<'PY'
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import shutil
import sys
import time
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat


SCHEMA_VERSION = 1
GENESIS_HASH = "0" * 64
ENCODING = "utf-8"
KEY_FILE = "audit-device.json"
LOG_FILE = "audit-events.jsonl"
RECEIPTS_DIR = "receipts"
ANCHORS_DIR = "anchors"
NONCE_LEN = 12
CMD_APPEND = "append"
CMD_ANCHOR = "anchor"
CMD_RECEIPT = "receipt"
FIELD_AUDIT_PRIVATE_KEY = "audit_signing_private_key"
FIELD_AUDIT_PUBLIC_KEY = "audit_signing_public_key"
FIELD_AUDIT_PAYLOAD_KEY = "audit_payload_key"
FIELD_AUDIT_RECORD_PUBLIC_KEY = "audit_public_key"
FIELD_ANCHOR = "anchor"
FIELD_DEVICE_ID = "device_id"
FIELD_HEAD = "head"
FIELD_OBSERVED_HEAD = "observed_head"
FIELD_OBSERVER_DEVICE = "observer_device"
FIELD_OBSERVER_PUBLIC_KEY = "observer_public_key"
FIELD_PREV_HASH = "prev_hash"
FIELD_RECEIPT = "receipt"
FIELD_RECORD_HASH = "record_hash"
FIELD_SCHEMA_VERSION = "schema_version"
FIELD_SEQUENCE = "sequence"
FIELD_SIGNATURE = "signature"
FIELD_TIMESTAMP = "timestamp"
FIELD_TRUSTED_OBSERVERS = "trusted_observers"
JSON_GLOB = "*.json"
ERR_CORRUPTED = "VAULT_AUDIT_CORRUPTED"
SAFE_RESULTS = {"attempt", "success", "failure", "denied", "warning"}
SENSITIVE_REJECTIONS = ("passphrase", "password", "secret", "token", "private_key", "recovery", "decrypted", "prompt")


class AuditError(Exception):
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


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def now() -> int:
    return int(time.time())


def vault_dir_from(value: str | None) -> Path:
    if value:
        return Path(value).expanduser()
    configured = os.environ.get("AIDEVOPS_VAULT_AUDIT_DIR") or os.environ.get("AIDEVOPS_VAULT_DIR")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".config" / "aidevops" / "vault" / "audit"


def private_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding=ENCODING)
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def write_public_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding=ENCODING)
    tmp.replace(path)


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding=ENCODING))
    except FileNotFoundError as exc:
        raise AuditError("VAULT_AUDIT_MISSING", f"Missing file: {path.name}", 2) from exc
    except json.JSONDecodeError as exc:
        raise AuditError(ERR_CORRUPTED, f"Invalid JSON: {path.name}", 3) from exc
    if not isinstance(data, dict):
        raise AuditError(ERR_CORRUPTED, f"Invalid JSON shape: {path.name}", 3)
    return data


def key_path(vault_dir: Path) -> Path:
    return vault_dir / KEY_FILE


def log_path(vault_dir: Path) -> Path:
    return vault_dir / LOG_FILE


def load_key(vault_dir: Path) -> dict[str, Any]:
    key = load_json(key_path(vault_dir))
    if key.get(FIELD_SCHEMA_VERSION) != SCHEMA_VERSION:
        raise AuditError("VAULT_AUDIT_KEY_CORRUPTED", "Unsupported audit key schema", 3)
    return key


def ensure_key(vault_dir: Path) -> dict[str, Any]:
    if key_path(vault_dir).exists():
        return load_key(vault_dir)
    cmd_init(argparse.Namespace(vault_dir=str(vault_dir), force=False, quiet=True))
    return load_key(vault_dir)


def read_records(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for line_no, line in enumerate(path.read_text(encoding=ENCODING).splitlines(), start=1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise AuditError(ERR_CORRUPTED, f"Invalid JSONL at line {line_no}", 3) from exc
        if not isinstance(item, dict):
            raise AuditError(ERR_CORRUPTED, f"Invalid record shape at line {line_no}", 3)
        records.append(item)
    return records


def sign_payload(payload: dict[str, Any], private_key_b64: str) -> str:
    private_key = Ed25519PrivateKey.from_private_bytes(b64d(private_key_b64))
    return b64e(private_key.sign(canonical(payload)))


def verify_signature(payload: dict[str, Any], signature: str, public_key_b64: str, code: str = "VAULT_AUDIT_BAD_SIGNATURE") -> None:
    public_key = Ed25519PublicKey.from_public_bytes(b64d(public_key_b64))
    try:
        public_key.verify(b64d(signature), canonical(payload))
    except InvalidSignature as exc:
        raise AuditError(code, "Vault audit signature is invalid", 4) from exc


def reject_sensitive(label: str, value: str) -> None:
    lowered = value.lower()
    if any(marker in lowered for marker in SENSITIVE_REJECTIONS):
        raise AuditError("VAULT_AUDIT_SENSITIVE_FIELD", f"Refusing to log sensitive {label}", 5)


def validate_safe_name(label: str, value: str) -> str:
    if not value or len(value) > 160:
        raise AuditError("VAULT_AUDIT_INVALID_FIELD", f"Invalid {label}", 2)
    reject_sensitive(label, value)
    return value


def last_state(records: list[dict[str, Any]]) -> tuple[int, str]:
    if not records:
        return 0, GENESIS_HASH
    last = records[-1]
    return int(last[FIELD_SEQUENCE]), str(last[FIELD_RECORD_HASH])


def record_hash(public_record: dict[str, Any]) -> str:
    return sha256_bytes(canonical(public_record))


def cmd_init(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    path = key_path(vault_dir)
    if path.exists() and not args.force:
        if not getattr(args, "quiet", False):
            print("Vault audit device key already exists")
        return 0
    signing_key = Ed25519PrivateKey.generate()
    public_key = signing_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    device_id = "audit-" + hashlib.sha256(public_key).hexdigest()[:32]
    payload = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "created_at": now(),
        FIELD_DEVICE_ID: device_id,
        FIELD_AUDIT_PRIVATE_KEY: b64e(signing_key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())),
        FIELD_AUDIT_PUBLIC_KEY: b64e(public_key),
        FIELD_AUDIT_PAYLOAD_KEY: b64e(secrets.token_bytes(32)),
    }
    private_write_json(path, payload)
    log_path(vault_dir).parent.mkdir(parents=True, exist_ok=True)
    log_path(vault_dir).touch(mode=0o600, exist_ok=True)
    os.chmod(log_path(vault_dir), 0o600)
    if not getattr(args, "quiet", False):
        print(device_id)
    return 0


def cmd_append(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    key = ensure_key(vault_dir)
    action = validate_safe_name("action", args.action)
    actor = validate_safe_name("actor", args.actor)
    target_collection = validate_safe_name("target collection", args.target_collection)
    result = validate_safe_name("result", args.result)
    if result not in SAFE_RESULTS:
        raise AuditError("VAULT_AUDIT_INVALID_RESULT", "Invalid audit result", 2)
    session_id = validate_safe_name("session id", args.session_id) if args.session_id else "none"
    reason = args.reason or ""
    if len(reason) > 240:
        raise AuditError("VAULT_AUDIT_INVALID_FIELD", "Audit reason is too long", 2)
    reject_sensitive("reason", reason)
    records = read_records(log_path(vault_dir))
    sequence, prev_hash = last_state(records)
    sequence += 1
    event_id = secrets.token_hex(16)
    event_payload = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "event_id": event_id,
        FIELD_DEVICE_ID: str(key[FIELD_DEVICE_ID]),
        FIELD_SEQUENCE: sequence,
        FIELD_PREV_HASH: prev_hash,
        FIELD_TIMESTAMP: now(),
        "actor": actor,
        "action": action,
        "target_collection": target_collection,
        "result": result,
        "session_id": session_id,
        "reason": reason,
    }
    nonce = secrets.token_bytes(NONCE_LEN)
    ciphertext = AESGCM(b64d(str(key[FIELD_AUDIT_PAYLOAD_KEY]))).encrypt(nonce, canonical(event_payload), b"aidevops-vault-audit-event")
    encrypted_event = {"aead": "AES-256-GCM", "nonce": b64e(nonce), "payload": b64e(ciphertext)}
    event_hash = sha256_bytes(canonical(encrypted_event))
    public_record = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "event_id": event_id,
        FIELD_DEVICE_ID: str(key[FIELD_DEVICE_ID]),
        FIELD_SEQUENCE: sequence,
        FIELD_PREV_HASH: prev_hash,
        FIELD_TIMESTAMP: event_payload[FIELD_TIMESTAMP],
        "event_hash": event_hash,
        "encrypted_event": encrypted_event,
        FIELD_AUDIT_RECORD_PUBLIC_KEY: str(key[FIELD_AUDIT_PUBLIC_KEY]),
    }
    public_record[FIELD_RECORD_HASH] = record_hash(public_record)
    signature_payload = {k: public_record[k] for k in sorted(public_record) if k != FIELD_SIGNATURE}
    public_record[FIELD_SIGNATURE] = sign_payload(signature_payload, str(key[FIELD_AUDIT_PRIVATE_KEY]))
    log_path(vault_dir).parent.mkdir(parents=True, exist_ok=True)
    with log_path(vault_dir).open("a", encoding=ENCODING) as handle:
        handle.write(json.dumps(public_record, sort_keys=True, separators=(",", ":")) + "\n")
    os.chmod(log_path(vault_dir), 0o600)
    print(public_record[FIELD_RECORD_HASH])
    return 0


def trusted_record_key(vault_dir: Path, explicit_public_key: str | None) -> tuple[str | None, str | None]:
    if explicit_public_key:
        return None, explicit_public_key
    key = load_key(vault_dir)
    return str(key[FIELD_DEVICE_ID]), str(key[FIELD_AUDIT_PUBLIC_KEY])


def verify_records(records: list[dict[str, Any]], trusted_device_id: str | None, trusted_public_key: str) -> tuple[int, str]:
    expected_prev = GENESIS_HASH
    expected_sequence = 1
    last_hash = GENESIS_HASH
    for record in records:
        try:
            sequence = int(record.get(FIELD_SEQUENCE, -1))
        except (TypeError, ValueError) as exc:
            raise AuditError(ERR_CORRUPTED, "Vault audit sequence is not a valid integer", 3) from exc
        if sequence != expected_sequence:
            raise AuditError("VAULT_AUDIT_SEQUENCE_GAP", "Vault audit sequence is missing or reordered", 6)
        if record.get(FIELD_PREV_HASH) != expected_prev:
            raise AuditError("VAULT_AUDIT_CHAIN_BROKEN", "Vault audit hash chain is broken", 6)
        if trusted_device_id and record.get(FIELD_DEVICE_ID) != trusted_device_id:
            raise AuditError("VAULT_AUDIT_UNTRUSTED_DEVICE", "Vault audit record device is not trusted", 4)
        if record.get(FIELD_AUDIT_RECORD_PUBLIC_KEY) != trusted_public_key:
            raise AuditError("VAULT_AUDIT_UNTRUSTED_KEY", "Vault audit record key is not trusted", 4)
        encrypted_event = record.get("encrypted_event")
        if not isinstance(encrypted_event, dict):
            raise AuditError(ERR_CORRUPTED, "Encrypted event is missing", 3)
        if record.get("event_hash") != sha256_bytes(canonical(encrypted_event)):
            raise AuditError("VAULT_AUDIT_EVENT_TAMPERED", "Vault audit encrypted payload hash changed", 6)
        stored_hash = str(record.get(FIELD_RECORD_HASH, ""))
        public_without_hash = {k: record[k] for k in record if k not in {FIELD_SIGNATURE, FIELD_RECORD_HASH}}
        if record_hash(public_without_hash) != stored_hash:
            raise AuditError("VAULT_AUDIT_RECORD_TAMPERED", "Vault audit record hash changed", 6)
        signature_payload = {k: record[k] for k in sorted(record) if k != FIELD_SIGNATURE}
        verify_signature(signature_payload, str(record.get(FIELD_SIGNATURE, "")), trusted_public_key)
        expected_prev = stored_hash
        last_hash = stored_hash
        expected_sequence += 1
    return expected_sequence - 1, last_hash


def load_trusted_observers(path_value: str | None) -> dict[str, str]:
    if not path_value:
        return {}
    data = load_json(Path(path_value))
    raw = data.get(FIELD_TRUSTED_OBSERVERS, data)
    if not isinstance(raw, dict):
        raise AuditError("VAULT_AUDIT_TRUSTED_KEYS_INVALID", "Trusted observer keys file has invalid shape", 3)
    return {str(k): str(v) for k, v in raw.items()}


def verify_receipt(path: Path, expected_head: str | None, trusted_observers: dict[str, str]) -> None:
    receipt = load_json(path)
    body = receipt.get(FIELD_RECEIPT)
    if not isinstance(body, dict):
        raise AuditError("VAULT_AUDIT_RECEIPT_CORRUPTED", "Receipt body is missing", 3)
    if expected_head and body.get(FIELD_OBSERVED_HEAD) != expected_head:
        raise AuditError("VAULT_AUDIT_RECEIPT_MISMATCH", "Receipt does not match audit head", 6)
    observer_device = str(body.get(FIELD_OBSERVER_DEVICE, ""))
    trusted_public_key = trusted_observers.get(observer_device, "")
    if not trusted_public_key:
        raise AuditError("VAULT_AUDIT_TRUSTED_PEER_REQUIRED", "Trusted peer audit key is required for receipt verification", 4)
    if body.get(FIELD_OBSERVER_PUBLIC_KEY) != trusted_public_key:
        raise AuditError("VAULT_AUDIT_UNTRUSTED_RECEIPT_KEY", "Receipt public key does not match trusted peer key", 4)
    verify_signature(body, str(receipt.get(FIELD_SIGNATURE, "")), trusted_public_key, "VAULT_AUDIT_BAD_RECEIPT_SIGNATURE")


def cmd_verify(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    records = read_records(Path(args.log) if args.log else log_path(vault_dir))
    trusted_device_id, trusted_public_key = trusted_record_key(vault_dir, args.trusted_public_key)
    sequence, head = verify_records(records, trusted_device_id, trusted_public_key)
    trusted_observers = load_trusted_observers(args.trusted_peer_keys)
    for receipt_file in args.receipt or []:
        verify_receipt(Path(receipt_file), head, trusted_observers)
    print(f"ok sequence={sequence} head={head}")
    return 0


def cmd_receipt(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    key = ensure_key(vault_dir)
    observer_device = validate_safe_name("observer device", args.observer_device)
    body = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "receipt_id": secrets.token_hex(16),
        FIELD_OBSERVER_DEVICE: observer_device,
        "observer_audit_device": str(key[FIELD_DEVICE_ID]),
        FIELD_OBSERVER_PUBLIC_KEY: str(key[FIELD_AUDIT_PUBLIC_KEY]),
        FIELD_OBSERVED_HEAD: validate_safe_name(FIELD_HEAD, args.head),
        "observed_sequence": int(args.sequence),
        "observed_at": now(),
    }
    envelope = {FIELD_RECEIPT: body, FIELD_SIGNATURE: sign_payload(body, str(key[FIELD_AUDIT_PRIVATE_KEY]))}
    output = Path(args.output) if args.output else vault_dir / RECEIPTS_DIR / f"{body['receipt_id']}.json"
    write_public_json(output, envelope)
    print(str(output))
    return 0


def cmd_anchor(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    key = ensure_key(vault_dir)
    anchor = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "anchor_id": secrets.token_hex(16),
        FIELD_DEVICE_ID: str(key[FIELD_DEVICE_ID]),
        FIELD_SEQUENCE: int(args.sequence),
        FIELD_HEAD: validate_safe_name(FIELD_HEAD, args.head),
        "created_at": now(),
        "public_safe": True,
    }
    envelope = {FIELD_ANCHOR: anchor, FIELD_SIGNATURE: sign_payload(anchor, str(key[FIELD_AUDIT_PRIVATE_KEY]))}
    output = Path(args.output) if args.output else vault_dir / ANCHORS_DIR / f"{anchor['anchor_id']}.json"
    write_public_json(output, envelope)
    print(str(output))
    return 0


def cmd_replicate(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    copied = 0
    if log_path(vault_dir).exists():
        shutil.copy2(log_path(vault_dir), output_dir / LOG_FILE)
        copied += 1
    for child_dir_name in (RECEIPTS_DIR, ANCHORS_DIR):
        source_dir = vault_dir / child_dir_name
        if source_dir.exists():
            target_dir = output_dir / child_dir_name
            target_dir.mkdir(parents=True, exist_ok=True)
            for source in source_dir.glob(JSON_GLOB):
                shutil.copy2(source, target_dir / source.name)
                copied += 1
    print(f"copied={copied}")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    records = read_records(log_path(vault_dir))
    trusted_device_id, trusted_public_key = trusted_record_key(vault_dir, None)
    sequence, head = verify_records(records, trusted_device_id, trusted_public_key)
    receipt_count = len(list((vault_dir / RECEIPTS_DIR).glob(JSON_GLOB))) if (vault_dir / RECEIPTS_DIR).exists() else 0
    anchor_count = len(list((vault_dir / ANCHORS_DIR).glob(JSON_GLOB))) if (vault_dir / ANCHORS_DIR).exists() else 0
    data = {"status": "ok", FIELD_SEQUENCE: sequence, FIELD_HEAD: head, "receipts": receipt_count, "anchors": anchor_count}
    if args.json:
        print(json.dumps(data, sort_keys=True))
    else:
        print(f"status=ok sequence={sequence} head={head} receipts={receipt_count} anchors={anchor_count}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vault-audit-helper.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--vault-dir")
    init = sub.add_parser("init", parents=[common])
    init.add_argument("--force", action="store_true")
    append = sub.add_parser(CMD_APPEND, parents=[common])
    append.add_argument("--actor", required=True)
    append.add_argument("--action", required=True)
    append.add_argument("--target-collection", required=True)
    append.add_argument("--result", required=True)
    append.add_argument("--session-id")
    append.add_argument("--reason")
    verify = sub.add_parser("verify", parents=[common])
    verify.add_argument("--log")
    verify.add_argument("--receipt", action="append")
    verify.add_argument("--trusted-public-key")
    verify.add_argument("--trusted-peer-keys")
    receipt = sub.add_parser(CMD_RECEIPT, parents=[common])
    receipt.add_argument("--head", required=True)
    receipt.add_argument("--sequence", required=True, type=int)
    receipt.add_argument("--observer-device", required=True)
    receipt.add_argument("--output")
    anchor = sub.add_parser(CMD_ANCHOR, parents=[common])
    anchor.add_argument("--head", required=True)
    anchor.add_argument("--sequence", required=True, type=int)
    anchor.add_argument("--output")
    replicate = sub.add_parser("replicate", parents=[common])
    replicate.add_argument("--output-dir", required=True)
    report = sub.add_parser("report", parents=[common])
    report.add_argument("--json", action="store_true")
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return {
            "init": cmd_init,
            CMD_APPEND: cmd_append,
            "verify": cmd_verify,
            CMD_RECEIPT: cmd_receipt,
            CMD_ANCHOR: cmd_anchor,
            "replicate": cmd_replicate,
            "report": cmd_report,
        }[args.command](args)
    except AuditError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return exc.exit_code


raise SystemExit(main(sys.argv[1:]))
PY
	exit $?
	;;
*)
	printf '%s\n' "[ERROR] Unknown Vault audit command: $command" >&2
	usage >&2
	exit 2
	;;
esac
