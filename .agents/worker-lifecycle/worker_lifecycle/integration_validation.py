"""Portable runner for registry contracts, using disposable state only."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import sqlite3
import subprocess  # nosec B404 # bounded execution of this validator's own suite
import sys
import tempfile
from typing import cast
import unittest
from uuid import uuid4
import zipfile

from .process import ObservationUnavailable
from .runtime import adapter_for, require_ready


TEST_MODULES = ("tests.test_storage", "tests.test_events", "tests.test_launch")


class ReportResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.checks = []

    def addSuccess(self, test):
        super().addSuccess(test)
        self.checks.append({"name": test.id(), "status": "passed"})

    def addError(self, test, err):
        super().addError(test, err)
        self.checks.append({"name": test.id(), "status": "error", "reason": err[0].__name__})

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.checks.append({"name": test.id(), "status": "failed", "reason": err[0].__name__})

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            # Parent identity only: subtest parameters may contain private input.
            status = "failed" if issubclass(err[0], test.failureException) else "error"
            self.checks.append({"name": test.id(), "status": status, "reason": err[0].__name__})

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.checks.append({"name": test.id(), "status": "skipped", "reason": "test-skipped"})


def run_suite() -> int:
    """Run inside the extracted package so owned child processes import it too."""
    report = {"schema": 1, "suite": "registry-integration", "status": "unavailable",
              "timestamp": datetime.now(timezone.utc).isoformat(),
              "system": platform.system(), "release": platform.release(),
              "machine": platform.machine(), "python": platform.python_version(),
              "sqlite": sqlite3.sqlite_version, "cleanup_authorized": False,
              "untested": ["power-loss", "disk-full", "reboot", "real-pid-reuse",
                           "real-ai-worker", "sandbox-launcher", "long-term-operation"]}
    try:
        if not hasattr(os, "getuid") or os.getuid() == 0 or os.geteuid() == 0:
            raise ObservationUnavailable("unprivileged-run-required")
        require_ready(adapter_for(str(uuid4())))
    except (ObservationUnavailable, OSError, ValueError) as error:
        report["reason"] = str(error) if isinstance(error, ObservationUnavailable) else type(error).__name__
        print(json.dumps(report, sort_keys=True))
        return 2
    suite = unittest.defaultTestLoader.loadTestsFromNames(TEST_MODULES)
    # unittest's return annotation does not preserve its supplied resultclass.
    result = cast(ReportResult, unittest.TextTestRunner(stream=sys.stderr, verbosity=2, resultclass=ReportResult).run(suite))
    report.update(tests_run=result.testsRun, checks=result.checks,
                  failures=len(result.failures), errors=len(result.errors), skipped=len(result.skipped))
    passed = result.wasSuccessful() and result.testsRun > 0 and not result.skipped
    report["status"] = "passed" if passed else "failed"
    print(json.dumps(report, sort_keys=True))
    return 0 if passed else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="new JSON report; existing files are never overwritten")
    args = parser.parse_args()
    # Reserve the report first: a typo or existing result must not trigger tests.
    output = None
    try:
        if args.output is not None:
            descriptor = os.open(args.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            output = os.fdopen(descriptor, "w", encoding="utf-8")
        artifact = Path(sys.argv[0]).resolve(strict=True)
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix="worker-lifecycle-validation-") as directory:
            root = Path(directory).resolve()
            with zipfile.ZipFile(artifact) as archive:
                names = archive.namelist()
                if len(names) > 32 or len(names) != len(set(names)):
                    raise ValueError("invalid-bundle-members")
                for info in archive.infolist():
                    path = PurePosixPath(info.filename)
                    unsafe_path = path.is_absolute() or ".." in path.parts or "\\" in info.filename
                    if unsafe_path:
                        raise ValueError("unsafe-bundle-path")
                    if path.suffix != ".py" or info.file_size > 262144:
                        raise ValueError("invalid-bundle-member")
                    target = root.joinpath(*path.parts)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(archive.read(info))
            environment = dict(os.environ, PYTHONPATH=str(root), PYTHONDONTWRITEBYTECODE="1", TMPDIR=str(root))
            command = [sys.executable, "-B", "-c",
                       "from worker_lifecycle.integration_validation import run_suite; raise SystemExit(run_suite())"]
            # No shell, AI runtime, scheduler or dependency installation is used.
            result = subprocess.run(command, cwd=root, env=environment, stdout=subprocess.PIPE,  # nosec B603 # fixed suite entry point
                                    text=True, timeout=180)
            report = json.loads(result.stdout)
            report["bundle_sha256"] = digest
        encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if output is not None:
            output.write(encoded)
            output.flush()
        print(encoded, end="")
        return result.returncode
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        report = {"schema": 1, "suite": "registry-integration", "status": "unavailable",
                  "reason": type(error).__name__, "cleanup_authorized": False}
        encoded = json.dumps(report) + "\n"
        if output is not None:
            output.write(encoded)
        print(encoded, end="")
        return 2
    finally:
        if output is not None:
            output.close()


if __name__ == "__main__":
    raise SystemExit(main())
