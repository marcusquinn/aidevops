#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fail closed when a termination command can target the active AI runtime."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from process_termination_common import (
    FORBID_EXIT,
    TERMINATORS,
    GuardError,
    ProcessRecord,
    RuntimeIdentityError,
    _allow,
    _forbid,
    _normalise_argv,
)
from process_termination_identity import (
    _load_fixture,
    _load_live_processes,
    _runtime_lineage,
)
from process_termination_kill import _evaluate_kill, _is_kill_inspection
from process_termination_killall import (
    _evaluate_killall,
    _is_killall_inspection,
)
from process_termination_pkill import _evaluate_pkill, _is_pkill_inspection

INSPECTION_CHECKS = {
    "kill": _is_kill_inspection,
    "killall": _is_killall_inspection,
    "pkill": _is_pkill_inspection,
}


def _load_processes(fixture: str) -> list[ProcessRecord]:
    if fixture:
        return _load_fixture(Path(fixture))
    return _load_live_processes()


def _evaluate_terminator(
    executable: str,
    argv: list[str],
    lineage: list[ProcessRecord],
    runtime_pid: int,
) -> dict[str, Any]:
    if executable == "kill":
        return _evaluate_kill(
            argv,
            runtime_pid,
            {record.pid for record in lineage},
            {record.pgid for record in lineage if record.pgid > 0},
        )
    if executable == "pkill":
        return _evaluate_pkill(argv, lineage)
    return _evaluate_killall(argv, lineage)


def evaluate(
    argv: list[str],
    runtime_pid: int,
    runtime_process_identity: str,
    fixture: str = "",
) -> dict[str, Any]:
    argv = _normalise_argv(argv)
    executable = os.path.basename(argv[0]) if argv else ""
    if executable not in TERMINATORS:
        result = _allow("No process-termination invocation detected")
    else:
        try:
            if INSPECTION_CHECKS[executable](argv):
                result = _allow(
                    "Process signal inspection does not terminate the runtime"
                )
            else:
                records = _load_processes(fixture)
                lineage = _runtime_lineage(
                    records, runtime_pid, runtime_process_identity
                )
                result = _evaluate_terminator(
                    executable, argv, lineage, runtime_pid
                )
        except RuntimeIdentityError as exc:
            result = _forbid(
                "process.runtime-identity-unavailable",
                f"Process termination blocked because {exc}",
            )
        except GuardError as exc:
            result = _forbid(
                "process.termination-unclassified",
                f"Process termination blocked because {exc}",
            )
    return result


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check",))
    parser.add_argument("--argv-json", required=True)
    parser.add_argument("--runtime-pid", required=True, type=int)
    parser.add_argument("--runtime-process-identity", default="")
    parser.add_argument("--process-table-fixture", default="")
    return parser


def main() -> int:
    args = _argument_parser().parse_args()
    try:
        argv = json.loads(args.argv_json)
    except json.JSONDecodeError:
        argv = None
    if not isinstance(argv, list) or not all(isinstance(item, str) for item in argv):
        result = _forbid(
            "process.runtime-identity-unavailable",
            "Process termination blocked because command arguments are malformed",
        )
    else:
        result = evaluate(
            argv,
            args.runtime_pid,
            args.runtime_process_identity,
            args.process_table_fixture,
        )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["decision"] == "allow" else FORBID_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
