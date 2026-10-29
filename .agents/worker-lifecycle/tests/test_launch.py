"""Exercise the pre-exec path with owned native processes, not an AI worker."""

import json
import os
from pathlib import Path
import subprocess  # nosec B404 # bounded owned launcher probes only
import sys
import tempfile
import unittest

from worker_lifecycle.registry import reconcile
from worker_lifecycle.storage import LifecycleRegistry


ENTRY = Path(__file__).resolve().parents[1] / "worker-launch.py"


class LaunchContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / "state"

    def command(self, code, initialize=False):
        return [sys.executable, "-E", "-s", "-B", str(ENTRY), "--state-dir", str(self.state),
                 "--worktree", str(self.root), *(["--initialize"] if initialize else []),
                 "--", sys.executable, "-I", "-B", "-c", code]

    def test_concurrent_first_launch_initializes_once(self):
        children = []
        try:
            for _ in range(8):
                children.append(subprocess.Popen(  # nosec B603 # owned concurrent startup probes
                    self.command("raise SystemExit(7)", initialize=True),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            for child in children:
                _, stderr = child.communicate(timeout=15)
                self.assertEqual(child.returncode, 7, stderr)
                self.assertIn("registered run=", stderr)
                self.assertNotIn("observation-gap", stderr)
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)
        summary = LifecycleRegistry(self.state).summary()
        self.assertEqual(summary["events"], 16)
        self.assertEqual(summary["runs"], {"bound": 8})
        self.assertFalse(summary["cleanup_authorized"])

    def test_initialization_preserves_unknown_existing_state(self):
        self.state.mkdir(mode=0o700)
        evidence = self.state / "preserved.txt"
        evidence.write_text("existing evidence")
        result = subprocess.run(  # nosec B603 # fixed failure probe
            self.command("raise SystemExit(9)", initialize=True),
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 9)
        self.assertIn("observation-gap", result.stderr)
        self.assertEqual(evidence.read_text(), "existing evidence")
        self.assertEqual(list(self.state.iterdir()), [evidence])

    def test_exec_identity_then_natural_exit(self):
        store = LifecycleRegistry.initialize(self.state)
        code = ("import os,select,sys; print(os.getpid(),flush=True); "
                "ready,_,_=select.select([sys.stdin],[],[],10); "
                "sys.stdin.read(1) if ready else None; sys.exit(7)")
        with subprocess.Popen(self.command(code), stdin=subprocess.PIPE,  # nosec B603 # fixed identity probe
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as child:
            try:
                native_pid = int(child.stdout.readline())
                self.assertEqual(native_pid, child.pid)
                rows = store.pending(10)
                self.assertEqual(len(rows), 1)
                self.assertEqual(json.loads(rows[0]["identity"])["pid"], native_pid)
                self.assertEqual(reconcile(store)["processed"], 1)
                self.assertEqual(store.summary()["runs"], {"bound": 1})
            finally:
                _, stderr = child.communicate(input="x", timeout=12)
            self.assertEqual(child.returncode, 7)
            self.assertIn("registered run=", stderr)
        self.assertEqual(reconcile(store)["processed"], 1)
        self.assertEqual(store.summary()["runs"], {"ended": 1})
        self.assertFalse(store.summary()["cleanup_authorized"])

    def test_unavailable_registry_preserves_command_and_exit(self):
        result = subprocess.run(self.command("print('native-output'); raise SystemExit(9)"),  # nosec B603 # fixed exit probe
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stdout, "native-output\n")
        self.assertIn("observation-gap", result.stderr)
        self.assertFalse(self.state.exists())

    def test_python_environment_cannot_block_observer_startup(self):
        environment = dict(os.environ, PYTHONHOME="/nonexistent-lifecycle-python-home",
                           PYTHONPATH="/nonexistent-lifecycle-python-path")
        result = subprocess.run(self.command("import os; print(os.environ['PYTHONHOME'])"),  # nosec B603 # fixed environment probe
                                env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), environment["PYTHONHOME"])
        self.assertIn("observation-gap", result.stderr)

    def test_full_registry_preserves_command_and_reports_gap(self):
        store = LifecycleRegistry.initialize(self.state, max_events=1)
        result = subprocess.run(self.command("print('native-output')"),  # nosec B603 # fixed capacity probe
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "native-output\n")
        self.assertIn("observation-gap reason=StoreCapacity", result.stderr)
        self.assertEqual(store.summary()["events"], 0)
        self.assertEqual(store.summary()["runs"], {})
        self.assertEqual(store.summary()["bindings"], 0)


if __name__ == "__main__":
    unittest.main()
