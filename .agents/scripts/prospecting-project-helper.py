#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Manage a local, private prospecting project store."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from prospecting_contract import ContractError
from prospecting_store import (
    ProspectingStoreError,
    connect,
    delete_project,
    export_project,
    import_document,
    list_leads,
    migrate,
    set_disposition,
)


def default_root() -> Path:
    configured = os.environ.get("AIDEVOPS_PROSPECTING_DIR")
    return Path(configured).expanduser() if configured else Path.home() / ".aidevops" / "prospecting"


def load_document(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise ProspectingStoreError("input must be a regular file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProspectingStoreError("input is not valid JSON") from error
    if not isinstance(value, dict):
        raise ProspectingStoreError("input must contain a JSON object")
    return value


def output(value: Any) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--store", type=Path, default=default_root(), help="private store directory")
    commands = root.add_subparsers(dest="command", required=True)

    init = commands.add_parser("init", help="initialize a project from a contract document")
    init.add_argument("--input", required=True, type=Path)

    load = commands.add_parser("import", help="validate and import evidence projections")
    load.add_argument("--input", required=True, type=Path)
    load.add_argument("--dry-run", action="store_true")

    listing = commands.add_parser("list", help="list one project's ranked leads")
    listing.add_argument("--project", required=True)
    listing.add_argument("--disposition")
    listing.add_argument("--limit", type=int, default=100)

    disposition = commands.add_parser("disposition", help="compare-and-swap one local disposition")
    disposition.add_argument("--project", required=True)
    disposition.add_argument("--lead", required=True)
    disposition.add_argument("--set", required=True, dest="value")
    disposition.add_argument("--expected-version", required=True, type=int)

    export = commands.add_parser("export", help="export private project state as JSON")
    export.add_argument("--project", required=True)

    delete = commands.add_parser("delete", help="delete one project after a verified local backup")
    delete.add_argument("--project", required=True)
    delete.add_argument("--confirm-name", required=True)
    return root


def run(arguments: argparse.Namespace) -> dict[str, Any]:
    raw = load_document(arguments.input) if hasattr(arguments, "input") else None
    if arguments.command == "import" and arguments.dry_run:
        assert raw is not None
        return import_document(None, raw, dry_run=True)
    database = connect(arguments.store)
    try:
        migrate(database)
        if arguments.command in ("init", "import"):
            assert raw is not None
            result = import_document(database, raw)
        elif arguments.command == "list":
            result = {"project_id": arguments.project, "leads": list_leads(database, arguments.project, disposition=arguments.disposition, limit=arguments.limit)}
        elif arguments.command == "disposition":
            changed = set_disposition(database, arguments.project, arguments.lead, arguments.value, arguments.expected_version)
            result = {"project_id": arguments.project, "lead_id": arguments.lead, "disposition": arguments.value, "version": changed}
        elif arguments.command == "export":
            result = export_project(database, arguments.project)
        elif arguments.command == "delete":
            backup = delete_project(database, arguments.store, arguments.project, arguments.confirm_name)
            result = {"deleted": arguments.project, "backup": str(backup)}
        else:
            raise ProspectingStoreError("unsupported command")
        return result
    finally:
        database.close()


def main() -> int:
    try:
        output(run(parser().parse_args()))
        return 0
    except (ContractError, ProspectingStoreError) as error:
        print(f"prospecting: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
