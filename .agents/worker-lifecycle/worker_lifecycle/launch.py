"""Opt-in pre-exec observation, not a supervisor or durable launch protocol."""

import argparse
import os
from pathlib import Path
import signal
import sqlite3
import sys
from uuid import uuid4

from .process import ObservationUnavailable
from .runtime import adapter_for, require_ready
from .store import LifecycleRegistry


def record(state_dir: Path, worktree: Path) -> str:
    store = LifecycleRegistry(state_dir)
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    run_id = str(uuid4())
    identity = adapter.capture(os.getpid())
    store.register(str(uuid4()), run_id, identity)
    # A per-attempt hypothetical binding, NOT a physical generation identity.
    # Register may persist if bind fails; diagnostics must report this gap.
    store.bind(str(uuid4()), run_id, str(uuid4()), str(worktree.resolve(strict=True)))
    return run_id


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--worktree", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a native command is required after --")
    try:
        run_id = record(args.state_dir, args.worktree)
        print(f"[worker-lifecycle] registered run={run_id} pid={os.getpid()}", file=sys.stderr)
    except (ValueError, OSError, RuntimeError, sqlite3.Error, ObservationUnavailable) as error:
        # Keep paths, command arguments and database contents out of logs.
        print(f"[worker-lifecycle] observation-gap reason={type(error).__name__}", file=sys.stderr)
    try:
        # Match subprocess restore_signals: CPython ignores these at startup,
        # but exec alone would pass those ignored dispositions to native code.
        for name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ"):
            number = getattr(signal, name, None)
            if number is not None:
                signal.signal(number, signal.SIG_DFL)
        # exec preserves PID/start identity and native exit code.
        # A command that spawns a separate runtime needs an explicit later binding.
        # argv is the explicit launcher CLI command, not registry/event input.
        # The calling launcher admits it before wrapping; no shell is introduced.
        # PATH and the installed runtime remain trusted caller inputs.
        # nosemgrep: python.lang.security.audit.dangerous-os-exec-tainted-env-args.dangerous-os-exec-tainted-env-args
        os.execvp(command[0], command)  # nosec B606 # intentional trusted launcher argv, no shell
    except OSError as error:
        print(f"[worker-lifecycle] exec-failed reason={type(error).__name__}", file=sys.stderr)
        return 127 if isinstance(error, FileNotFoundError) else 126
    return 126


if __name__ == "__main__":
    raise SystemExit(main())
