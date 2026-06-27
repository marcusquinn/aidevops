#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
GIT_TRANSPORT_HELPER="${AIDEVOPS_VAULT_GIT_TRANSPORT_HELPER:-${SCRIPT_DIR}/vault-git-transport-helper.sh}"

if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" || $# -eq 0 ]]; then
	cat <<'EOF'
Usage: vault-message-helper.sh <command> [options]

Commands:
  init [--vault-dir DIR] [--force]
      Create local-only message signing/encryption keys and print a public descriptor.
  public [--vault-dir DIR] [--output FILE]
      Print or write the public descriptor for another trusted device.
  send --recipient FILE --class CLASS --body-file FILE --repo DIR [--vault-dir DIR]
       [--transport git|simplex] [--expires-at EPOCH] [--pad-bytes N]
      Encrypt and sign a device message, then stage it on the selected transport.
  receive --repo DIR [--vault-dir DIR] [--revoked-devices FILE]
      Collect encrypted messages. Decrypt only when AIDEVOPS_VAULT_MESSAGE_UNLOCKED=1.
  inbox [--vault-dir DIR] [--json]
      Show encrypted/decrypted inbox counts without exposing plaintext message bodies.
  outbox [--vault-dir DIR] [--json]
      Show sent message ids and acknowledgement state.
  ack --message-id ID --repo DIR [--vault-dir DIR]
      Stage a signed acknowledgement for a received message.
  prune [--vault-dir DIR] [--before EPOCH]
      Remove expired decrypted cache entries and old transport staging files.

Message classes: human, sync-request, audit-receipt, lock-command,
  unlock-request, unlock-grant, unlock-grant-envelope-placeholder.

Passphrases, recovery material, and Vault data keys are never accepted through
arguments, environment variables, logs, issue bodies, chat, or fixtures. Git and
SimpleX are untrusted transports; message files contain opaque ids, signatures,
expiry, nonces, padding, and ciphertext only.
EOF
	exit 0
fi

command_name="${1-}"
shift || true

case "$command_name" in
	init | public | send | receive | inbox | outbox | ack | prune)
		python3 - "$command_name" "$GIT_TRANSPORT_HELPER" "$@" <<'PY'
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


SCHEMA_VERSION = 1
ENCODING = "utf-8"
KEY_FILE = "message-device.json"
INBOX_FILE = "message-inbox.json"
OUTBOX_FILE = "message-outbox.json"
REPLAY_FILE = "message-replay-cache.json"
LOCAL_ENCRYPTED_DIR = "message-encrypted-inbox"
LOCAL_OUTBOX_DIR = "message-outbox-files"
LOCAL_ACK_DIR = "message-acks"
AAD = b"aidevops-vault-device-message-v1"
FIELD_BODY = "body"
FIELD_CLASS = "class"
FIELD_CREATED_AT = "created_at"
FIELD_DECRYPTED = "decrypted"
FIELD_DEVICE_ID = "device_id"
FIELD_ENCRYPTED = "encrypted"
FIELD_ENCRYPTION_PRIVATE_KEY = "encryption_private_key"
FIELD_ENCRYPTION_PUBLIC_KEY = "encryption_public_key"
FIELD_LAST_SEQUENCE = "last_sequence"
FIELD_MAILBOX_ID = "mailbox_id"
FIELD_MESSAGE = "message"
FIELD_MESSAGE_ID = "message_id"
FIELD_MESSAGES = "messages"
FIELD_RECIPIENT_MAILBOX_ID = "recipient_mailbox_id"
FIELD_SCHEMA_VERSION = "schema_version"
FIELD_SENDER_DEVICE = "sender_device"
FIELD_SENDER_MAILBOX_ID = "sender_mailbox_id"
FIELD_SIGNING_PUBLIC_KEY = "signing_public_key"
ARG_REPO = "--repo"
ARG_VAULT_DIR = "--vault-dir"
ACTION_STORE_TRUE = "store_true"
MESSAGE_CLASSES = {
    "human",
    "sync-request",
    "audit-receipt",
    "lock-command",
    "unlock-request",
    "unlock-grant",
    "unlock-grant-envelope-placeholder",
}


class MessageError(Exception):
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
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding=ENCODING)
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def public_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding=ENCODING)
    tmp.replace(path)


def load_json(path: Path, code: str = "VAULT_MESSAGE_MISSING") -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding=ENCODING))
    except FileNotFoundError as exc:
        raise MessageError(code, f"Missing file: {path.name}", 2) from exc
    except json.JSONDecodeError as exc:
        raise MessageError("VAULT_MESSAGE_CORRUPTED", f"Invalid JSON: {path.name}", 3) from exc
    if not isinstance(data, dict):
        raise MessageError("VAULT_MESSAGE_CORRUPTED", f"Invalid JSON shape: {path.name}", 3)
    return data


def key_path(vault_dir: Path) -> Path:
    return vault_dir / KEY_FILE


def load_key(vault_dir: Path) -> dict[str, Any]:
    key = load_json(key_path(vault_dir), "VAULT_MESSAGE_UNINITIALIZED")
    if key.get(FIELD_SCHEMA_VERSION) != SCHEMA_VERSION:
        raise MessageError("VAULT_MESSAGE_KEY_CORRUPTED", "Unsupported message key schema", 3)
    return key


def public_descriptor(key: dict[str, Any]) -> dict[str, Any]:
    return {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        FIELD_DEVICE_ID: str(key[FIELD_DEVICE_ID]),
        FIELD_MAILBOX_ID: str(key[FIELD_MAILBOX_ID]),
        FIELD_SIGNING_PUBLIC_KEY: str(key[FIELD_SIGNING_PUBLIC_KEY]),
        FIELD_ENCRYPTION_PUBLIC_KEY: str(key[FIELD_ENCRYPTION_PUBLIC_KEY]),
        "message_classes": sorted(MESSAGE_CLASSES),
    }


def cmd_init(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    path = key_path(vault_dir)
    if path.exists() and not args.force:
        raise MessageError("VAULT_MESSAGE_KEY_EXISTS", "Vault message device key already exists", 2)
    signing_key = Ed25519PrivateKey.generate()
    encryption_key = X25519PrivateKey.generate()
    signing_public = signing_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    encryption_public = encryption_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    device_id = hashlib.sha256(signing_public + encryption_public).hexdigest()
    mailbox_id = hashlib.sha256(b"mailbox:" + encryption_public).hexdigest()
    payload = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        FIELD_CREATED_AT: int(time.time()),
        FIELD_DEVICE_ID: device_id,
        FIELD_MAILBOX_ID: mailbox_id,
        "signing_private_key": b64e(signing_key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())),
        FIELD_SIGNING_PUBLIC_KEY: b64e(signing_public),
        FIELD_ENCRYPTION_PRIVATE_KEY: b64e(encryption_key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())),
        FIELD_ENCRYPTION_PUBLIC_KEY: b64e(encryption_public),
        FIELD_LAST_SEQUENCE: 0,
    }
    private_write_json(path, payload)
    print(json.dumps(public_descriptor(payload), sort_keys=True))
    return 0


def cmd_public(args: argparse.Namespace) -> int:
    key = load_key(vault_dir_from(args.vault_dir))
    descriptor = public_descriptor(key)
    if args.output:
        public_write_json(Path(args.output), descriptor)
    else:
        print(json.dumps(descriptor, sort_keys=True))
    return 0


def sign_payload(payload: dict[str, Any], private_key_b64: str) -> str:
    signing_key = Ed25519PrivateKey.from_private_bytes(b64d(private_key_b64))
    return b64e(signing_key.sign(canonical(payload)))


def verify_payload(payload: dict[str, Any], signature: str, public_key_b64: str, code: str = "VAULT_MESSAGE_BAD_SIGNATURE") -> None:
    public_key = Ed25519PublicKey.from_public_bytes(b64d(public_key_b64))
    try:
        public_key.verify(b64d(signature), canonical(payload))
    except InvalidSignature as exc:
        raise MessageError(code, "Vault message signature is invalid", 4) from exc


def derive_message_key(private_key: X25519PrivateKey, public_key: X25519PublicKey, message_id: str) -> bytes:
    shared = private_key.exchange(public_key)
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=message_id.encode(ENCODING), info=AAD).derive(shared)


def load_revoked(path_value: str | None) -> set[str]:
    if not path_value:
        return set()
    data = load_json(Path(path_value))
    revoked = data.get("revoked_devices", [])
    if not isinstance(revoked, list):
        raise MessageError("VAULT_MESSAGE_REVOKED_INVALID", "Revoked device list is invalid", 3)
    return {str(item) for item in revoked}


def ensure_transport_available(transport: str) -> None:
    if transport == "git":
        return
    if transport == "simplex":
        adapter = os.environ.get("AIDEVOPS_VAULT_SIMPLEX_ADAPTER")
        if not adapter or not shutil.which(adapter):
            raise MessageError("VAULT_MESSAGE_SIMPLEX_UNAVAILABLE", "SimpleX adapter is unavailable; message was not sent", 6)
        return
    raise MessageError("VAULT_MESSAGE_TRANSPORT_UNKNOWN", "Unknown Vault message transport", 2)


def cmd_send(args: argparse.Namespace) -> int:
    ensure_transport_available(args.transport)
    if args.message_class not in MESSAGE_CLASSES:
        raise MessageError("VAULT_MESSAGE_CLASS_INVALID", "Unsupported Vault message class", 2)
    vault_dir = vault_dir_from(args.vault_dir)
    key = load_key(vault_dir)
    recipient = load_json(Path(args.recipient))
    body = Path(args.body_file).read_bytes()
    message_id = secrets.token_hex(32)
    sequence = int(key.get(FIELD_LAST_SEQUENCE, 0)) + 1
    pad_bytes = max(0, int(args.pad_bytes))
    plaintext = {
        FIELD_CLASS: args.message_class,
        FIELD_BODY: b64e(body),
        "padding": b64e(secrets.token_bytes(pad_bytes)) if pad_bytes else "",
    }
    sender_private = X25519PrivateKey.from_private_bytes(b64d(str(key[FIELD_ENCRYPTION_PRIVATE_KEY])))
    recipient_public = X25519PublicKey.from_public_bytes(b64d(str(recipient[FIELD_ENCRYPTION_PUBLIC_KEY])))
    nonce = secrets.token_bytes(12)
    ciphertext = AESGCM(derive_message_key(sender_private, recipient_public, message_id)).encrypt(nonce, canonical(plaintext), AAD)
    message = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        FIELD_MESSAGE_ID: message_id,
        "message_class_hash": hashlib.sha256(args.message_class.encode(ENCODING)).hexdigest(),
        FIELD_SENDER_DEVICE: str(key[FIELD_DEVICE_ID]),
        FIELD_SENDER_MAILBOX_ID: str(key[FIELD_MAILBOX_ID]),
        "sender_public_key": str(key[FIELD_SIGNING_PUBLIC_KEY]),
        "sender_encryption_public_key": str(key[FIELD_ENCRYPTION_PUBLIC_KEY]),
        "recipient_device": str(recipient["device_id"]),
        FIELD_RECIPIENT_MAILBOX_ID: str(recipient[FIELD_MAILBOX_ID]),
        "sequence": sequence,
        FIELD_CREATED_AT: int(time.time()),
        "expires_at": int(args.expires_at) if args.expires_at else None,
        "nonce": b64e(nonce),
        "ciphertext": b64e(ciphertext),
    }
    envelope = {FIELD_MESSAGE: message, "signature": sign_payload(message, str(key["signing_private_key"]))}
    outbox_dir = vault_dir / LOCAL_OUTBOX_DIR
    message_file = outbox_dir / f"{message_id}.json"
    public_write_json(message_file, envelope)
    if args.transport == "git":
        subprocess.run(["bash", args.git_helper, "stage-message", ARG_REPO, args.repo, "--message", str(message_file)], check=True, stdout=subprocess.PIPE, text=True)
    else:
        subprocess.run([os.environ["AIDEVOPS_VAULT_SIMPLEX_ADAPTER"], "send", str(message_file)], check=True)
    outbox = load_json(vault_dir / OUTBOX_FILE) if (vault_dir / OUTBOX_FILE).exists() else {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_MESSAGES: {}}
    messages = dict(outbox.get(FIELD_MESSAGES, {}))
    messages[message_id] = {FIELD_CLASS: args.message_class, FIELD_RECIPIENT_MAILBOX_ID: str(recipient[FIELD_MAILBOX_ID]), FIELD_CREATED_AT: message[FIELD_CREATED_AT], "acked": False}
    private_write_json(vault_dir / OUTBOX_FILE, {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_MESSAGES: messages})
    key[FIELD_LAST_SEQUENCE] = sequence
    private_write_json(key_path(vault_dir), key)
    print(message_id)
    return 0


def local_unlocked() -> bool:
    return os.environ.get("AIDEVOPS_VAULT_MESSAGE_UNLOCKED") == "1"


def load_replay(vault_dir: Path) -> dict[str, Any]:
    path = vault_dir / REPLAY_FILE
    if not path.exists():
        return {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_MESSAGES: {}}
    return load_json(path)


def require_message_string_fields(message: dict[str, Any], fields: tuple[str, ...]) -> None:
    for field in fields:
        if field not in message or not isinstance(message[field], str):
            raise MessageError("VAULT_MESSAGE_INVALID", f"Message is missing or has invalid field: {field}", 3)


def decrypt_message(key: dict[str, Any], message: dict[str, Any]) -> dict[str, Any]:
    recipient_private = X25519PrivateKey.from_private_bytes(b64d(str(key[FIELD_ENCRYPTION_PRIVATE_KEY])))
    sender_public = X25519PublicKey.from_public_bytes(b64d(str(message["sender_encryption_public_key"])))
    plaintext = AESGCM(derive_message_key(recipient_private, sender_public, str(message[FIELD_MESSAGE_ID]))).decrypt(
        b64d(str(message["nonce"])), b64d(str(message["ciphertext"])), AAD
    )
    return json.loads(plaintext.decode(ENCODING))


def cmd_receive(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    key = load_key(vault_dir)
    encrypted_dir = vault_dir / LOCAL_ENCRYPTED_DIR
    encrypted_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(encrypted_dir, 0o700)
    subprocess.run(["bash", args.git_helper, "collect-messages", ARG_REPO, args.repo, "--mailbox-id", str(key[FIELD_MAILBOX_ID]), "--output", str(encrypted_dir)], check=True, stdout=subprocess.PIPE, text=True)
    revoked = load_revoked(args.revoked_devices)
    replay = load_replay(vault_dir)
    seen = dict(replay.get(FIELD_MESSAGES, {}))
    inbox = load_json(vault_dir / INBOX_FILE) if (vault_dir / INBOX_FILE).exists() else {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_ENCRYPTED: {}, FIELD_DECRYPTED: {}}
    encrypted = dict(inbox.get(FIELD_ENCRYPTED, {}))
    decrypted = dict(inbox.get(FIELD_DECRYPTED, {}))
    now = int(time.time())
    received = 0
    decrypted_count = 0
    for message_file in sorted(encrypted_dir.glob("*.json")):
        envelope = load_json(message_file)
        message = envelope.get(FIELD_MESSAGE)
        if not isinstance(message, dict):
            raise MessageError("VAULT_MESSAGE_INVALID", "Vault message envelope is invalid", 3)
        require_message_string_fields(message, (FIELD_MESSAGE_ID, "sender_public_key", "sender_encryption_public_key", "nonce", "ciphertext"))
        signature = envelope.get("signature")
        if not isinstance(signature, str):
            raise MessageError("VAULT_MESSAGE_INVALID", "Message is missing or has invalid field: signature", 3)
        verify_payload(message, signature, str(message["sender_public_key"]))
        message_id = str(message[FIELD_MESSAGE_ID])
        if message_id in seen:
            continue
        expires_at = message.get("expires_at")
        if expires_at is not None and int(expires_at) < now:
            raise MessageError("VAULT_MESSAGE_EXPIRED", "Vault message is expired", 4)
        sender = str(message.get(FIELD_SENDER_DEVICE, ""))
        if sender in revoked:
            raise MessageError("VAULT_MESSAGE_REVOKED_DEVICE", "Vault message sender is revoked", 4)
        encrypted[message_id] = {
            "class_hash": message.get("message_class_hash"),
            FIELD_SENDER_DEVICE: sender,
            FIELD_SENDER_MAILBOX_ID: message.get(FIELD_SENDER_MAILBOX_ID),
            FIELD_CREATED_AT: message.get(FIELD_CREATED_AT),
            "path": str(message_file.name),
        }
        if local_unlocked():
            payload = decrypt_message(key, message)
            decrypted[message_id] = {FIELD_CLASS: payload.get(FIELD_CLASS), FIELD_BODY: payload.get(FIELD_BODY), FIELD_SENDER_DEVICE: sender, "decrypted_at": now}
            decrypted_count += 1
        seen[message_id] = {FIELD_SENDER_DEVICE: sender, "received_at": now}
        received += 1
    private_write_json(vault_dir / INBOX_FILE, {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_ENCRYPTED: encrypted, FIELD_DECRYPTED: decrypted})
    private_write_json(vault_dir / REPLAY_FILE, {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_MESSAGES: seen})
    print(json.dumps({"received": received, FIELD_DECRYPTED: decrypted_count, "locked": not local_unlocked()}, sort_keys=True))
    return 0


def cmd_inbox(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    inbox = load_json(vault_dir / INBOX_FILE) if (vault_dir / INBOX_FILE).exists() else {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_ENCRYPTED: {}, FIELD_DECRYPTED: {}}
    encrypted = dict(inbox.get(FIELD_ENCRYPTED, {}))
    decrypted = dict(inbox.get(FIELD_DECRYPTED, {}))
    summary = {"encrypted_count": len(encrypted), "decrypted_count": len(decrypted), "locked": not local_unlocked()}
    print(json.dumps(summary, sort_keys=True) if args.json else f"encrypted={summary['encrypted_count']} decrypted={summary['decrypted_count']} locked={str(summary['locked']).lower()}")
    return 0


def cmd_outbox(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    outbox = load_json(vault_dir / OUTBOX_FILE) if (vault_dir / OUTBOX_FILE).exists() else {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_MESSAGES: {}}
    print(json.dumps(outbox, sort_keys=True) if args.json else f"messages={len(dict(outbox.get(FIELD_MESSAGES, {})))}")
    return 0


def cmd_ack(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    key = load_key(vault_dir)
    inbox = load_json(vault_dir / INBOX_FILE)
    encrypted = dict(inbox.get(FIELD_ENCRYPTED, {}))
    if args.message_id not in encrypted:
        raise MessageError("VAULT_MESSAGE_ACK_UNKNOWN", "Cannot acknowledge an unknown message", 2)
    ack_id = secrets.token_hex(32)
    ack = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "ack_id": ack_id,
        FIELD_MESSAGE_ID: args.message_id,
        FIELD_SENDER_DEVICE: str(key[FIELD_DEVICE_ID]),
        FIELD_SENDER_MAILBOX_ID: str(key[FIELD_MAILBOX_ID]),
        FIELD_RECIPIENT_MAILBOX_ID: str(encrypted[args.message_id].get(FIELD_SENDER_MAILBOX_ID, "")),
        "status": "received",
        FIELD_CREATED_AT: int(time.time()),
    }
    if len(str(ack[FIELD_RECIPIENT_MAILBOX_ID])) != 64:
        raise MessageError("VAULT_MESSAGE_ACK_INVALID", "Cannot acknowledge message without an opaque sender mailbox", 3)
    envelope = {"ack": ack, "signature": sign_payload(ack, str(key["signing_private_key"]))}
    ack_dir = vault_dir / LOCAL_ACK_DIR
    ack_file = ack_dir / f"{ack_id}.json"
    public_write_json(ack_file, envelope)
    subprocess.run(["bash", args.git_helper, "stage-ack", ARG_REPO, args.repo, "--ack", str(ack_file)], check=True, stdout=subprocess.PIPE, text=True)
    print(ack_id)
    return 0


def cmd_prune(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    before = int(args.before or time.time())
    removed = 0
    for directory_name in (LOCAL_ENCRYPTED_DIR, LOCAL_OUTBOX_DIR, LOCAL_ACK_DIR):
        directory = vault_dir / directory_name
        if not directory.exists():
            continue
        for path in directory.glob("*.json"):
            if int(path.stat().st_mtime) < before:
                path.unlink()
                removed += 1
    print(json.dumps({"removed": removed}, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vault-message-helper.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    init_p = sub.add_parser("init")
    init_p.add_argument(ARG_VAULT_DIR)
    init_p.add_argument("--force", action=ACTION_STORE_TRUE)
    init_p.set_defaults(func=cmd_init)
    public_p = sub.add_parser("public")
    public_p.add_argument(ARG_VAULT_DIR)
    public_p.add_argument("--output")
    public_p.set_defaults(func=cmd_public)
    send_p = sub.add_parser("send")
    send_p.add_argument(ARG_VAULT_DIR)
    send_p.add_argument("--recipient", required=True)
    send_p.add_argument("--class", dest="message_class", required=True)
    send_p.add_argument("--body-file", required=True)
    send_p.add_argument(ARG_REPO, required=True)
    send_p.add_argument("--transport", choices=["git", "simplex"], default="git")
    send_p.add_argument("--expires-at")
    send_p.add_argument("--pad-bytes", default="0")
    send_p.set_defaults(func=cmd_send)
    receive_p = sub.add_parser("receive")
    receive_p.add_argument(ARG_VAULT_DIR)
    receive_p.add_argument(ARG_REPO, required=True)
    receive_p.add_argument("--revoked-devices")
    receive_p.set_defaults(func=cmd_receive)
    inbox_p = sub.add_parser("inbox")
    inbox_p.add_argument(ARG_VAULT_DIR)
    inbox_p.add_argument("--json", action=ACTION_STORE_TRUE)
    inbox_p.set_defaults(func=cmd_inbox)
    outbox_p = sub.add_parser("outbox")
    outbox_p.add_argument(ARG_VAULT_DIR)
    outbox_p.add_argument("--json", action=ACTION_STORE_TRUE)
    outbox_p.set_defaults(func=cmd_outbox)
    ack_p = sub.add_parser("ack")
    ack_p.add_argument(ARG_VAULT_DIR)
    ack_p.add_argument("--message-id", required=True)
    ack_p.add_argument(ARG_REPO, required=True)
    ack_p.set_defaults(func=cmd_ack)
    prune_p = sub.add_parser("prune")
    prune_p.add_argument(ARG_VAULT_DIR)
    prune_p.add_argument("--before")
    prune_p.set_defaults(func=cmd_prune)
    return parser


def main() -> int:
    command = sys.argv[1]
    git_helper = sys.argv[2]
    args = build_parser().parse_args([command] + sys.argv[3:])
    args.git_helper = git_helper
    try:
        return int(args.func(args))
    except MessageError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
PY
		;;
	*)
		printf '%s\n' "[ERROR] Unknown Vault message command: $command_name" >&2
		exit 2
		;;
esac
