"""Pre-exec observation, not a supervisor or durable launch protocol."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import sqlite3
import subprocess  # nosec B404 # exception type only; Git execution is audited in enrollment.py
import sys
import time
from uuid import uuid4

from .admission import AdmissionClosed, AdmissionRegistry
from .directory_handle import DirectoryHandle
from .enrollment import GenerationEnrollment
from .process import ObservationUnavailable
from .runtime import adapter_for, require_ready
from .storage import LifecycleRegistry


def initialize_or_open(state_dir: Path) -> LifecycleRegistry:
    """Claim a new directory, or wait briefly for another initializer's commit.

    Existing state is only opened and validated, never repaired or replaced.
    A crashed initializer therefore produces a visible gap, not evidence loss.
    """
    try:
        return LifecycleRegistry.initialize(state_dir)
    except FileExistsError:
        deadline = time.monotonic() + 2
        while True:
            try:
                store = LifecycleRegistry(state_dir)
                store.installation_id()
                return store
            except (OSError, ValueError, sqlite3.Error):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)


def record(state_dir: Path, worktree: Path, initialize: bool = False) -> str:
    # Check the platform before creating persistent state. Rebind the adapter
    # to the stored installation identity after readiness has been established.
    require_ready(adapter_for(str(uuid4())))
    store = initialize_or_open(state_dir) if initialize else LifecycleRegistry(state_dir)
    adapter = adapter_for(store.installation_id())
    run_id = str(uuid4())
    identity = adapter.capture(os.getpid())
    # A per-attempt hypothetical binding, NOT a physical generation identity.
    # Resolve before the transaction; a failed bind must not leave a partial run.
    store.register_attempt(run_id, identity, str(uuid4()), str(worktree.resolve(strict=True)))
    return run_id


def enrolled_generation(state_dir: Path, worktree: Path, initialize: bool) -> tuple[str, Path] | None:
    """Select registered generations, never infer them from legacy bindings.

    Bootstrap failures still belong to the observe-only rollout gap. A known
    admission row, however, must never degrade into hypothetical registration.
    """
    require_ready(adapter_for(str(uuid4())))
    store = initialize_or_open(state_dir) if initialize else LifecycleRegistry(state_dir)
    # A declared reservation must not disappear through symlink resolution.
    path = Path(os.path.abspath(worktree))
    with store.connection() as connection:
        if connection.execute("PRAGMA user_version").fetchone()[0] == 1:
            return None
        row = connection.execute("SELECT 1 FROM generation_admissions WHERE path=?", (str(path),)).fetchone()
        if row is None:
            path = worktree.resolve(strict=True)
            row = connection.execute("SELECT 1 FROM generation_admissions WHERE path=?", (str(path),)).fetchone()
    if row is None:
        return None
    try:
        return GenerationEnrollment(store).resolve(path), path
    except (ValueError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as error:
        raise AdmissionClosed("enrolled-generation-unavailable") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--worktree", required=True, type=Path)
    parser.add_argument("--initialize", action="store_true", help="create absent private state; never replace existing state")
    parser.add_argument("--generation-id", help="require admission to this pre-reserved generation; no fail-open fallback")
    parser.add_argument("--run-id", help="stable attempt ID required with --generation-id; replay never executes again")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a native command is required after --")
    if (args.generation_id is None) != (args.run_id is None):
        parser.error("--generation-id and --run-id must be supplied together")
    if args.generation_id is not None:
        if args.initialize:
            parser.error("admission requires existing state; --initialize is not allowed")
        return run_admitted(args.state_dir, args.worktree, args.run_id, args.generation_id, command)
    try:
        enrollment = enrolled_generation(args.state_dir, args.worktree, args.initialize)
        if enrollment is not None:
            generation, path = enrollment
            return run_admitted(args.state_dir, path, str(uuid4()), generation, command)
        run_id = record(args.state_dir, args.worktree, args.initialize)
        print(f"[worker-lifecycle] registered run={run_id} pid={os.getpid()}", file=sys.stderr)
    except AdmissionClosed:
        print("[worker-lifecycle] admission-denied reason=enrolled-generation-unavailable", file=sys.stderr)
        return 75
    except (ValueError, OSError, RuntimeError, sqlite3.Error, ObservationUnavailable) as error:
        # Keep paths, command arguments and database contents out of logs.
        print(f"[worker-lifecycle] observation-gap reason={type(error).__name__}", file=sys.stderr)
    return execute(command)


def run_admitted(state_dir: Path, worktree: Path, run_id: str, generation_id: str, command: list[str]) -> int:
    """Fail closed before exec; registration is not descendant containment."""
    try:
        with DirectoryHandle(worktree) as handle:
            store = LifecycleRegistry(state_dir)
            adapter = adapter_for(store.installation_id())
            require_ready(adapter)
            identity = adapter.capture(os.getpid())
            if not AdmissionRegistry(store).admit(run_id, identity, generation_id, str(worktree)):
                raise AdmissionClosed("replay-is-not-execution-authority")
            if not handle.matches_path():
                raise ValueError("directory-changed-before-exec")
            return execute(command, admitted=True)
    except (ValueError, OSError, RuntimeError, sqlite3.Error, ObservationUnavailable) as error:
        print(f"[worker-lifecycle] admission-denied reason={type(error).__name__}", file=sys.stderr)
        return 75


def execute(command: list[str], *, admitted: bool = False) -> int:
    """Replace this process, preserving the existing native command contract."""
    environment = os.environ.copy()
    if admitted:
        # These select this attempt, not a descendant's future admission.
        environment.pop("AIDEVOPS_LIFECYCLE_RUN_ID", None)
        environment.pop("AIDEVOPS_LIFECYCLE_GENERATION_ID", None)
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
        os.execvpe(command[0], command, environment)  # noqa: S606  # nosec B606
    except OSError as error:
        print(f"[worker-lifecycle] exec-failed reason={type(error).__name__}", file=sys.stderr)
        return 127 if isinstance(error, FileNotFoundError) else 126
    return 126


if __name__ == "__main__":
    raise SystemExit(main())
