#!/usr/bin/env python3
"""Fail-closed contract for the privileged inspector's batched --cwds mode (GH#38918)."""

import importlib.util
import pathlib
import unittest
from unittest import mock


INSPECTOR_PATH = pathlib.Path(__file__).resolve().parents[1] / "worktree-cwd-inspect.py"
SPEC = importlib.util.spec_from_file_location("worktree_cwd_inspect", INSPECTOR_PATH)
assert SPEC is not None and SPEC.loader is not None
inspector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inspector)

LEGACY_RESULTS = {
    "5": "/srv/worktrees/wt-5",
    "7": PermissionError("private detail must not escape"),
    "8": "/srv/worktrees/\udcff",  # undecodable byte via surrogateescape
    "9": "/srv/worktrees/wt-9",
}


class BatchCwdTests(unittest.TestCase):
    def test_each_pid_gets_the_legacy_read_and_failures_stay_opaque(self):
        reads = mock.Mock(side_effect=[LEGACY_RESULTS[pid] for pid in ("5", "7", "8", "9")])
        with mock.patch.object(inspector, "legacy_cwd", reads):
            report = inspector.cwds_report(["5", "7", "8", "9"], 1002)
        self.assertEqual(reads.call_args_list, [mock.call(pid, 1002) for pid in ("5", "7", "8", "9")])
        self.assertEqual(report.splitlines(), [
            "aidevops-cwd-inspect\tcwds\t1\t4", "R\t5\t/srv/worktrees/wt-5",
            "F\t7", "F\t8", "R\t9\t/srv/worktrees/wt-9", "end\t4"])

    def test_invalid_duplicate_empty_or_oversized_requests_are_refused_before_reads(self):
        oversized = [str(number) for number in range(1, inspector.CWDS_MAX_PIDS + 2)]
        for pids in ([], ["0"], ["5", "5"], ["5", "x"], ["-1"], ["05"], ["5\t6"], oversized):
            with self.subTest(count=len(pids), first=pids[:1]):
                with mock.patch.object(inspector, "legacy_cwd") as reads:
                    self.assertRaises(ValueError, inspector.cwds_report, pids, 1002)
                reads.assert_not_called()

    def test_main_routes_batches_through_the_five_second_child_deadline(self):
        with (mock.patch.object(inspector.os, "geteuid", return_value=0),
              mock.patch.dict(inspector.os.environ, {"SUDO_UID": "1002"}),
              mock.patch.object(inspector.sys, "argv", ["inspector", "--cwds", "5", "9"]),
              mock.patch.object(inspector, "bounded_report", return_value=0) as bounded):
            self.assertEqual(inspector.main(), 0)
        deadline, build = bounded.call_args.args
        self.assertEqual((deadline, build.func, build.args), (5, inspector.cwds_report, (["5", "9"], 1002)))

    def test_legacy_mode_still_takes_exactly_one_pid(self):
        for argv in (["inspector"], ["inspector", "5", "9"], ["inspector", "--cwds-typo", "5"]):
            with self.subTest(argv=argv):
                with (mock.patch.object(inspector.os, "geteuid", return_value=0),
                      mock.patch.dict(inspector.os.environ, {"SUDO_UID": "1002"}),
                      mock.patch.object(inspector.sys, "argv", argv),
                      mock.patch.object(inspector, "legacy_cwd") as reads):
                    self.assertEqual(inspector.main(), 1)
                reads.assert_not_called()


if __name__ == "__main__":
    unittest.main()
