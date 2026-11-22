"""Portable native validation of the actual process adapters, without installation.

Only this process and its owned, bounded child are inspected. Identity values
travel to a fresh observer through stdin, never through arguments or the report.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
from importlib.resources import files
import json
import math
import os
from pathlib import Path
import platform
import select
import sqlite3
import statistics
import subprocess  # nosec B404 # bounded owned probes with fixed code
import sys
import time
from typing import TypedDict
from uuid import uuid4

from .process import ObservationUnavailable, ProcessAdapter, ProcessIdentity
from .runtime import adapter_for, require_ready


SCHEMA = "worker-lifecycle.validation/v1"


class Environment(TypedDict, total=False):
    platform: str
    kernel_release: str
    process_arch: str
    python_version: str
    sqlite_version: str
    unprivileged: bool
    os_version: str
    distribution: dict[str, str | None] | None


class ValidationReport(TypedDict, total=False):
    schema: str
    observed_at: str
    environment: Environment
    code_sha256: str | None
    checks: dict[str, str]
    performance: dict[str, str | int | float | bool] | None
    verdict: str
    owned_children_reaped: bool
    forced_child_cleanup: bool
    untested: list[str]
    coverage: dict[str, str]
    next_steps: list[dict[str, str]]
    limitations: list[str]
    error: dict[str, str | int | None]
    elapsed_seconds: float


OBSERVER = """import json,sys
sys.path.insert(0, sys.argv[1])
from worker_lifecycle.process import ProcessIdentity
from worker_lifecycle.runtime import adapter_for, require_ready
value=json.loads(sys.stdin.read(16385))
identity=ProcessIdentity.from_dict(value)
adapter=adapter_for(identity.installation_id)
require_ready(adapter)
print(json.dumps(adapter.observe(identity).to_dict()))
"""
CHILD = """import select,sys
print('ready', flush=True)
ready,_,_=select.select([sys.stdin],[],[],15)
if ready:
    sys.stdin.read(1)
"""


def environment() -> Environment:
    result: Environment = {
        "platform": sys.platform, "kernel_release": platform.release(),
        "process_arch": platform.machine(), "python_version": platform.python_version(),
        "sqlite_version": sqlite3.sqlite_version,
        "unprivileged": hasattr(os, "getuid") and os.getuid() != 0 and os.geteuid() != 0,
    }
    if sys.platform == "darwin":
        result["os_version"] = platform.mac_ver()[0]
    elif sys.platform == "linux":
        try:
            release = platform.freedesktop_os_release()
            result["distribution"] = {key: release.get(key) for key in ("ID", "VERSION_ID")}
        except OSError:
            result["distribution"] = None
    return result


def source_digest() -> str:
    """Identify tested code independently of Git checkout or private paths."""
    digest = hashlib.sha256()
    root = files("worker_lifecycle")
    for name in ("process.py", "runtime.py", "linux.py", "macos.py", "validation.py"):
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update((root / name).read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def record(report: ValidationReport, name: str, passed: bool) -> None:
    report["checks"][name] = "pass" if passed else "fail"


def check_catalog() -> dict:
    return {
        "default": {"available": True, "option": None,
                    "description": "readiness, identity, live child, fresh observer, reap, performance"},
        "zombie-state": {"available": True, "option": "--check zombie-state",
                         "description": "observe only our exited child before reaping it"},
        "reboot": {"available": False, "reason": "two-phase reboot protocol not implemented; never reboots automatically"},
        "real-pid-reuse": {"available": False, "reason": "bounded real PID-reuse experiment not implemented"},
        "timestamp-uniqueness": {"available": False, "reason": "requires native API guarantees; a finite sample cannot prove uniqueness"},
        "process-access-denial": {"available": False, "reason": "native denial scenario not implemented; injected tests are separate"},
        "native-abi-against-installed-sdk": {
            "available": False,
            "applicable": sys.platform == "darwin",
            "reason": "SDK comparison not implemented in portable validator; macOS only"},
        "other-os-builds": {"available": False, "reason": "run this bundle on each target OS and compare reports"},
    }


def observe_zombie(adapter: ProcessAdapter, identity: ProcessIdentity, report: ValidationReport) -> None:
    # Do not call poll()/wait(): they reap the child. Production observation
    # distinguishes process-exited (zombie) from pid-absent (after reap).
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        result = adapter.observe(identity)
        if result.status == "ended":
            passed = result.reason == "process-exited"
            record(report, "zombie_state", passed)
            report["coverage"]["zombie-state"] = "passed" if passed else "failed"
            return
        if result.status == "unknown":
            raise ObservationUnavailable("zombie-observation-unavailable")
        time.sleep(0.01)
    raise ObservationUnavailable("zombie-observation-timeout")


def observe_child(adapter: ProcessAdapter, report: ValidationReport, zombie: bool = False) -> None:
    child = subprocess.Popen(  # nosec B603 # fixed CHILD probe in the current interpreter
        [sys.executable, "-I", "-B", "-c", CHILD], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, close_fds=True,
    )
    report["owned_children_reaped"] = False
    identity = None
    try:
        if child.stdout is None or child.stdin is None:
            raise ObservationUnavailable("child-pipes-unavailable")
        if not select.select([child.stdout], [], [], 3)[0] or child.stdout.readline() != b"ready\n":
            raise ObservationUnavailable("child-readiness-timeout")
        identity = adapter.capture(child.pid)
        record(report, "child_pid_matches", identity.pid == child.pid)
        record(report, "child_alive", adapter.observe(identity).status == "alive")
        record(report, "identity_stable", adapter.capture(child.pid) == identity)
        # A fresh isolated interpreter imports this exact checkout, not an
        # installed package with the same name or an inherited PYTHONPATH.
        fresh = subprocess.run(  # nosec B603 # fixed OBSERVER code; identity is stdin data
            [sys.executable, "-I", "-B", "-c", OBSERVER, str(Path(__file__).parent.parent)],
            input=json.dumps(identity.to_dict()), capture_output=True, text=True,
            timeout=5, close_fds=True,
        )
        matched = fresh.returncode == 0 and json.loads(fresh.stdout).get("status") == "alive"
        record(report, "fresh_observer_matches", matched)
        if zombie:
            child.stdin.close()
            observe_zombie(adapter, identity, report)
    finally:
        if child.stdin is not None and not child.stdin.closed:
            child.stdin.close()
        try:
            code = child.wait(timeout=17)
        except subprocess.TimeoutExpired:
            child.kill()  # Only this probe's child, never an existing process.
            code = child.wait(timeout=3)
            report["forced_child_cleanup"] = True
        finally:
            if child.stdout is not None:
                child.stdout.close()
        report["owned_children_reaped"] = True
        record(report, "child_natural_exit", code == 0 and not report["forced_child_cleanup"])
    if identity is not None:
        record(report, "after_reap_ended", adapter.observe(identity).status == "ended")


def measure(adapter: ProcessAdapter, identity: ProcessIdentity, count: int) -> dict[str, str | int | float | bool]:
    values = []
    for _ in range(count):
        started = time.perf_counter_ns()
        observation = adapter.observe(identity)
        values.append((time.perf_counter_ns() - started) / 1000)
        if observation.status != "alive":
            raise ObservationUnavailable("performance-observation-unavailable")
    return {
        "samples": count, "median_us": statistics.median(values),
        "p95_us": sorted(values)[math.ceil(count * 0.95) - 1],
        "scope": "complete-adapter-observation-including-context-checks",
        "initialization_excluded": True,
    }


def collect(samples: int = 100, zombie: bool = False) -> ValidationReport:
    if not 1 <= samples <= 1000:
        raise ValueError("sample-count-out-of-range")
    started = time.monotonic()
    report: ValidationReport = {
        "schema": SCHEMA, "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment": environment(), "code_sha256": None,
        "checks": {}, "performance": None, "verdict": "blocked",
        "owned_children_reaped": True, "forced_child_cleanup": False,
        "untested": ["reboot", "real-pid-reuse", "timestamp-uniqueness", "process-access-denial",
                     "native-abi-against-installed-sdk", "zombie-state", "other-os-builds"],
        "coverage": {"zombie-state": "not_run",
                     "native-abi-against-installed-sdk": "not_run" if sys.platform == "darwin" else "not_applicable"},
        "next_steps": [],
        "limitations": ["Process death does not prove descendant quiescence or cleanup safety.",
                        "Installation UUID is temporary; no real registry is read or changed.",
                        "No native build tool, dependency installation or SDK is required.",
                        "Matching metadata does not prove timestamp uniqueness."],
    }
    stage = "environment"
    try:
        if not report["environment"]["unprivileged"]:
            raise ObservationUnavailable("unprivileged-user-required")
        report["code_sha256"] = source_digest()
        stage = "readiness"
        adapter = adapter_for(str(uuid4()))
        require_ready(adapter)
        record(report, "readiness", True)
        stage = "self"
        identity = adapter.capture(os.getpid())
        restored = ProcessIdentity.from_dict(json.loads(json.dumps(identity.to_dict())))
        record(report, "identity_round_trip", identity == restored)
        record(report, "self_alive", adapter.observe(restored).status == "alive")
        stage = "child"
        observe_child(adapter, report, zombie=zombie)
        stage = "performance"
        report["performance"] = measure(adapter, identity, samples)
        report["verdict"] = "passed" if all(v == "pass" for v in report["checks"].values()) else "failed"
    except (ObservationUnavailable, OSError, ValueError, AttributeError, subprocess.SubprocessError) as error:
        # No traceback, argv, private identity, or arbitrary exception message.
        report["error"] = {"stage": stage, "type": type(error).__name__,
                           "errno": getattr(error, "errno", None)}
        report["checks"][stage] = "blocked"
        report["verdict"] = "partial" if report["checks"].get("readiness") == "pass" else "blocked"
    report["elapsed_seconds"] = round(time.monotonic() - started, 4)
    if report["coverage"]["zombie-state"] in {"passed", "failed"}:
        report["untested"].remove("zombie-state")
    if sys.platform != "darwin":
        report["untested"].remove("native-abi-against-installed-sdk")
    if not zombie:
        report["next_steps"].append({"check": "zombie-state", "option": "--check zombie-state",
                                     "description": "Rerun with this option and a new report filename."})
    report["next_steps"].append({"option": "--list-checks", "description": "Show available checks and reasons for unavailable scenarios."})
    return report


def write_report(path: Path, report: ValidationReport) -> None:
    """Explicit output only, exclusive creation, private permissions."""
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(payload)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="new JSON report; never overwrites or creates parent directories")
    parser.add_argument("--samples", type=int, choices=range(1, 1001), metavar="1..1000", default=100)
    parser.add_argument("--list-checks", action="store_true", help="list implemented and unavailable checks without probing")
    parser.add_argument("--check", choices=("zombie-state",), help="also test the owned child's zombie state before reap")
    args = parser.parse_args()
    if args.list_checks:
        print(json.dumps({"schema": SCHEMA, "catalog": check_catalog()}, indent=2, sort_keys=True))
        return 0
    report = collect(args.samples, zombie=args.check == "zombie-state")
    if args.output:
        try:
            write_report(args.output, report)
        except OSError as error:
            print(json.dumps({"schema": SCHEMA, "error": "report-write-failed",
                              "errno": error.errno}), file=sys.stderr)
            return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["verdict"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
