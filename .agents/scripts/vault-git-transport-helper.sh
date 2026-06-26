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

Transport paths are derived from record ids only. They must not include private
filenames, namespaces, local paths, client names, or plaintext record contents.
EOF
	exit 0
fi

command_name="${1-}"
shift || true

case "$command_name" in
	stage | collect)
		python3 - "$command_name" "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path


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
        raise TransportError("VAULT_TRANSPORT_INVALID", "Record file is invalid JSON", 3) from exc
    record = data.get("record") if isinstance(data, dict) else None
    if not isinstance(record, dict) or not isinstance(record.get("record_id"), str):
        raise TransportError("VAULT_TRANSPORT_INVALID", "Record id is missing", 3)
    return data


def record_target(repo: Path, record_id: str) -> Path:
    safe = "".join(ch for ch in record_id if ch in "0123456789abcdef")
    if len(safe) < 32 or safe != record_id:
        raise TransportError("VAULT_TRANSPORT_BAD_ID", "Record id is not opaque hex", 3)
    return repo / ".vault" / "records" / safe[:2] / f"{safe}.json"


def cmd_stage(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    record_file = Path(args.record)
    data = load_record(record_file)
    target = record_target(repo, str(data["record"]["record_id"]))
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".json.tmp")
    shutil.copyfile(record_file, tmp)
    tmp.replace(target)
    print(str(target.relative_to(repo)))
    return 0


def cmd_collect(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    count = 0
    root = repo / ".vault" / "records"
    if root.exists():
        for record_file in sorted(root.glob("[0-9a-f][0-9a-f]/*.json")):
            data = load_record(record_file)
            target = output / f"{data['record']['record_id']}.json"
            shutil.copyfile(record_file, target)
            count += 1
    print(str(count))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vault-git-transport-helper.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    stage_p = sub.add_parser("stage")
    stage_p.add_argument("--repo", required=True)
    stage_p.add_argument("--record", required=True)
    stage_p.set_defaults(func=cmd_stage)
    collect_p = sub.add_parser("collect")
    collect_p.add_argument("--repo", required=True)
    collect_p.add_argument("--output", required=True)
    collect_p.set_defaults(func=cmd_collect)
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
