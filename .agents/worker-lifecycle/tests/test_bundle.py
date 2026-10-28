"""Single-file distribution must work without a checkout on sys.path."""

from pathlib import Path
import subprocess  # nosec B404 # bounded execution of locally built test artifacts
import sys
import tempfile
import unittest
import zipfile

from worker_lifecycle.bundle import build


class BundleContract(unittest.TestCase):
    def test_reproducible_and_preserves_failed_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            first, second = root / "first.pyz", root / "second.pyz"
            build(first)
            build(second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with self.assertRaises(FileExistsError):
                build(first)
            with zipfile.ZipFile(first) as archive:
                self.assertNotIn("worker_lifecycle/store.py", archive.namelist())
            listed = subprocess.run([sys.executable, "-I", "-B", str(first), "--list-checks"],  # nosec B603 # bundle built above
                                    cwd=root, capture_output=True, text=True, timeout=5)
            self.assertEqual(listed.returncode, 0, listed.stderr)
            # Selecting the existing bundle as report output must fail without
            # overwriting it, and the zipapp must propagate main()'s exit code.
            failed = subprocess.run([sys.executable, "-I", "-B", str(first), "--samples", "1",  # nosec B603 # bundle built above
                                     "--output", str(first)], cwd=root, capture_output=True,
                                    text=True, timeout=35)
            self.assertEqual(failed.returncode, 2, failed.stdout)
            self.assertEqual(first.read_bytes(), second.read_bytes())


if __name__ == "__main__":
    unittest.main()
