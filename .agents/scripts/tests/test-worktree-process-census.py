#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Linux path-census coverage extracted from the owner lifetime suite."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worktree_process_census as census


class ProcessCensusTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux", "Linux procfs required")
    def test_live_cwd_fd_and_environment_references_are_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            # These children start outside the target except in the cwd case.
            scripts = ["import time; time.sleep(30)",
                       "import os,time; fd=os.open(%r, os.O_RDONLY); time.sleep(30)" % directory,
                       "import time; time.sleep(30)", "import time; time.sleep(30)"]
            for index, script in enumerate(scripts):
                env = dict(os.environ)
                env.update({"PWD": os.path.sep, "AIDEVOPS_WORKTREE": os.path.sep})
                if index >= 2:
                    env[("PWD", "AIDEVOPS_WORKTREE")[index - 2]] = directory
                child = subprocess.Popen(  # nosec B603 -- current interpreter, fixed fixture code and disposable cwd
                    [sys.executable, "-c", script], cwd=directory if index == 0 else "/", env=env)
                try:
                    # Wait boundedly for the fd child to open its target.
                    deadline = time.monotonic() + 5
                    while not census.inspect_path_references(Path(f"/proc/{child.pid}"), str(path)):
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                    sample = census.path_census(str(path))
                    self.assertGreaterEqual(sample["references"], 1)
                finally:
                    child.terminate()
                    child.wait(timeout=5)

    def test_path_boundaries_deleted_links_and_unreadable_census(self):
        self.assertTrue(census.under_worktree("/worktree/file (deleted)", "/worktree"))
        self.assertFalse(census.under_worktree("/worktree-other/file", "/worktree"))
        with patch.object(census, "inspect_path_references", side_effect=PermissionError()):
            sample = census.path_census("/worktree")
            if sys.platform == "linux":
                self.assertGreater(sample["uncertain"], 0)

    def test_all_threads_are_inspected_and_unknown_threads_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            process = Path(directory)
            (process / "task").mkdir()
            for tid in (100, 101):
                task = process / "task" / str(tid)
                task.mkdir()
                (task / "status").write_text("Uid:\t" + "\t".join([str(os.getuid())] * 4) + "\n")
            result = {"references": 0, "uncertain": 0}
            with patch.object(census, "inspect_path_references",
                              side_effect=lambda task, path: task.name == "101") as inspect:
                census.collect_path_references(process, "/worktree", result)
                self.assertEqual(inspect.call_count, 2)
                self.assertEqual(result["references"], 1)
            with patch.object(census, "inspect_path_references", side_effect=PermissionError()):
                census.collect_path_references(process, "/worktree", result)
                self.assertEqual(result["uncertain"], 2)

    @unittest.skipUnless(sys.platform == "linux", "Linux procfs required")
    def test_non_dumpable_same_uid_child_is_not_silently_skipped(self):
        script = ("import ctypes,sys,time; "
                  "assert ctypes.CDLL(None).prctl(4,0,0,0,0)==0; "
                  "print('ready',flush=True); time.sleep(30)")
        with tempfile.TemporaryDirectory() as directory:
            child = subprocess.Popen(  # nosec B603 -- current interpreter, constant prctl/sleep fixture, no shell
                [sys.executable, "-c", script], cwd=directory, stdout=subprocess.PIPE, text=True)
            try:
                import select
                self.assertTrue(select.select([child.stdout], [], [], 5)[0])
                self.assertEqual(child.stdout.readline().strip(), "ready")
                sample = census.path_census(directory)
                self.assertTrue(sample["references"] or sample["uncertain"] or
                                sample["status"] == "unavailable")
            finally:
                child.terminate()
                child.wait(timeout=5)
                child.stdout.close()

    def test_filtered_or_namespace_mismatched_proc_is_not_negative_evidence(self):
        status = "NSpid:\t%s\n" % os.getpid()
        mount = "1 0 0:1 / /proc rw - proc proc rw,hidepid=2\n"
        with patch.object(Path, "read_text", side_effect=[status, mount]), \
                self.assertRaisesRegex(ValueError, "filtered proc"):
            census.require_proc_visibility()
        with patch.object(Path, "read_text", return_value=status.rstrip() + " 42\n"), \
                self.assertRaisesRegex(ValueError, "namespace mismatch"):
            census.require_proc_visibility()


if __name__ == "__main__":
    unittest.main()
