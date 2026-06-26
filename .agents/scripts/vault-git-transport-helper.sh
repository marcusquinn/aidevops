#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" || $# -eq 0 ]]; then
	cat <<'EOF'
Usage: vault-git-transport-helper.sh <command> [options]

Commands:
  stage --repo DIR --record FILE
      Copy an encrypted sync record into an opaque public-Git-safe path.
  collect --repo DIR --output DIR
      Copy encrypted sync records from the transport into a local directory.
  stage-message --repo DIR --message FILE
      Copy an encrypted device message into an opaque mailbox path.
  collect-messages --repo DIR --mailbox-id ID --output DIR
      Copy encrypted device messages for one opaque mailbox into a local inbox.
  stage-ack --repo DIR --ack FILE
      Copy a signed device-message acknowledgement into an opaque ack path.
  collect-acks --repo DIR --mailbox-id ID --output DIR
      Copy signed acknowledgements for one opaque mailbox into a local directory.

Transport paths are derived from record ids only. They must not include private
filenames, namespaces, local paths, client names, message subjects, or plaintext
record contents.
EOF
	exit 0
fi

command_name="${1-}"
shift || true

case "$command_name" in
	stage | collect | stage-message | collect-messages | stage-ack | collect-acks)
		python3 - "$command_name" "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

FIELD_ACK = "ack"
FIELD_ACK_ID = "ack_id"
FIELD_MESSAGE = "message"
FIELD_MESSAGE_ID = "message_id"
DIR_MESSAGES = "messages"
DIR_VAULT = ".vault"
ERR_INVALID = "VAULT_TRANSPORT_INVALID"
HEX_PAIR_JSON_GLOB = "[0-9a-f][0-9a-f]/*.json"
JSON_TMP_SUFFIX = ".json.tmp"
LABEL_MAILBOX_ID = "Mailbox id"
ARG_OUTPUT = "--output"
ARG_REPO = "--repo"


class TransportError(Exception):
    def __init__(self, code: str, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


def load_record(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise TransportError("VAULT_TRANSPORT_MISSING", "Record file is missing", 2) from exc
    except json.JSONDecodeError as exc:
        raise TransportError(ERR_INVALID, "Record file is invalid JSON", 3) from exc
    record = data.get("record") if isinstance(data, dict) else None
    if not isinstance(record, dict) or not isinstance(record.get("record_id"), str):
        raise TransportError(ERR_INVALID, "Record id is missing", 3)
    return data


def record_target(repo: Path, record_id: str) -> Path:
    safe = "".join(ch for ch in record_id if ch in "0123456789abcdef")
    if len(safe) < 32 or safe != record_id:
        raise TransportError("VAULT_TRANSPORT_BAD_ID", "Record id is not opaque hex", 3)
    return repo / DIR_VAULT / "records" / safe[:2] / f"{safe}.json"


def safe_hex(value: str, field: str, min_len: int = 32) -> str:
    safe = "".join(ch for ch in value if ch in "0123456789abcdef")
    if len(safe) < min_len or safe != value:
        raise TransportError("VAULT_TRANSPORT_BAD_ID", f"{field} is not opaque hex", 3)
    return safe


def load_envelope(path: Path, object_name: str, id_field: str) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise TransportError("VAULT_TRANSPORT_MISSING", f"{object_name} file is missing", 2) from exc
    except json.JSONDecodeError as exc:
        raise TransportError(ERR_INVALID, f"{object_name} file is invalid JSON", 3) from exc
    payload = data.get(object_name) if isinstance(data, dict) else None
    if not isinstance(payload, dict) or not isinstance(payload.get(id_field), str):
        raise TransportError(ERR_INVALID, f"{object_name} id is missing", 3)
    return data


def message_target(repo: Path, mailbox_id: str, message_id: str) -> Path:
    mailbox = safe_hex(mailbox_id, LABEL_MAILBOX_ID)
    message = safe_hex(message_id, "Message id")
    return repo / DIR_VAULT / DIR_MESSAGES / "inbox" / mailbox[:2] / mailbox / message[:2] / f"{message}.json"


def ack_target(repo: Path, mailbox_id: str, ack_id: str) -> Path:
    mailbox = safe_hex(mailbox_id, LABEL_MAILBOX_ID)
    ack = safe_hex(ack_id, "Acknowledgement id")
    return repo / DIR_VAULT / DIR_MESSAGES / "acks" / mailbox[:2] / mailbox / ack[:2] / f"{ack}.json"


def cmd_stage(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    record_file = Path(args.record)
    data = load_record(record_file)
    target = record_target(repo, str(data["record"]["record_id"]))
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(JSON_TMP_SUFFIX)
    shutil.copyfile(record_file, tmp)
    tmp.replace(target)
    print(str(target.relative_to(repo)))
    return 0


def cmd_collect(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    count = 0
    root = repo / DIR_VAULT / "records"
    if root.exists():
        for record_file in sorted(root.glob(HEX_PAIR_JSON_GLOB)):
            data = load_record(record_file)
            target = output / f"{data['record']['record_id']}.json"
            shutil.copyfile(record_file, target)
            count += 1
    print(str(count))
    return 0


def cmd_stage_message(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    message_file = Path(args.message)
    data = load_envelope(message_file, FIELD_MESSAGE, FIELD_MESSAGE_ID)
    message = data[FIELD_MESSAGE]
    target = message_target(repo, str(message["recipient_mailbox_id"]), str(message[FIELD_MESSAGE_ID]))
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(JSON_TMP_SUFFIX)
    shutil.copyfile(message_file, tmp)
    tmp.replace(target)
    print(str(target.relative_to(repo)))
    return 0


def cmd_collect_messages(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    mailbox_id = safe_hex(str(args.mailbox_id), LABEL_MAILBOX_ID)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    count = 0
    root = repo / DIR_VAULT / DIR_MESSAGES / "inbox" / mailbox_id[:2] / mailbox_id
    if root.exists():
        for message_file in sorted(root.glob(HEX_PAIR_JSON_GLOB)):
            data = load_envelope(message_file, FIELD_MESSAGE, FIELD_MESSAGE_ID)
            target = output / f"{data[FIELD_MESSAGE][FIELD_MESSAGE_ID]}.json"
            shutil.copyfile(message_file, target)
            count += 1
    print(str(count))
    return 0


def cmd_stage_ack(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    ack_file = Path(args.ack)
    data = load_envelope(ack_file, FIELD_ACK, FIELD_ACK_ID)
    ack = data[FIELD_ACK]
    target = ack_target(repo, str(ack["recipient_mailbox_id"]), str(ack[FIELD_ACK_ID]))
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(JSON_TMP_SUFFIX)
    shutil.copyfile(ack_file, tmp)
    tmp.replace(target)
    print(str(target.relative_to(repo)))
    return 0


def cmd_collect_acks(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    mailbox_id = safe_hex(str(args.mailbox_id), LABEL_MAILBOX_ID)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    count = 0
    root = repo / DIR_VAULT / DIR_MESSAGES / "acks" / mailbox_id[:2] / mailbox_id
    if root.exists():
        for ack_file in sorted(root.glob(HEX_PAIR_JSON_GLOB)):
            data = load_envelope(ack_file, FIELD_ACK, FIELD_ACK_ID)
            target = output / f"{data[FIELD_ACK][FIELD_ACK_ID]}.json"
            shutil.copyfile(ack_file, target)
            count += 1
    print(str(count))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vault-git-transport-helper.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    stage_p = sub.add_parser("stage")
    stage_p.add_argument(ARG_REPO, required=True)
    stage_p.add_argument("--record", required=True)
    stage_p.set_defaults(func=cmd_stage)
    collect_p = sub.add_parser("collect")
    collect_p.add_argument(ARG_REPO, required=True)
    collect_p.add_argument(ARG_OUTPUT, required=True)
    collect_p.set_defaults(func=cmd_collect)
    stage_message_p = sub.add_parser("stage-message")
    stage_message_p.add_argument(ARG_REPO, required=True)
    stage_message_p.add_argument("--message", required=True)
    stage_message_p.set_defaults(func=cmd_stage_message)
    collect_messages_p = sub.add_parser("collect-messages")
    collect_messages_p.add_argument(ARG_REPO, required=True)
    collect_messages_p.add_argument("--mailbox-id", required=True)
    collect_messages_p.add_argument(ARG_OUTPUT, required=True)
    collect_messages_p.set_defaults(func=cmd_collect_messages)
    stage_ack_p = sub.add_parser("stage-ack")
    stage_ack_p.add_argument(ARG_REPO, required=True)
    stage_ack_p.add_argument("--ack", required=True)
    stage_ack_p.set_defaults(func=cmd_stage_ack)
    collect_acks_p = sub.add_parser("collect-acks")
    collect_acks_p.add_argument(ARG_REPO, required=True)
    collect_acks_p.add_argument("--mailbox-id", required=True)
    collect_acks_p.add_argument(ARG_OUTPUT, required=True)
    collect_acks_p.set_defaults(func=cmd_collect_acks)
    return parser


def main() -> int:
    args = build_parser().parse_args(sys.argv[1:])
    try:
        return int(args.func(args))
    except TransportError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
PY
		;;
	*)
		printf '%s\n' "[ERROR] Unknown Vault Git transport command: $command_name" >&2
		exit 2
		;;
esac
