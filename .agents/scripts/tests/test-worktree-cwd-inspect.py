#!/usr/bin/env python3
"""Fail-closed contract for the optional privileged CWD inspector."""

import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import types
import unittest
from unittest import mock


INSPECTOR_PATH = pathlib.Path(__file__).resolve().parents[1] / "worktree-cwd-inspect.py"
SPEC = importlib.util.spec_from_file_location("worktree_cwd_inspect", INSPECTOR_PATH)
assert SPEC is not None and SPEC.loader is not None
inspector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inspector)


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.candidate = self.root / "candidate"
        self.candidate.mkdir()
        self.proc = self.root / "proc"
        self.process = self.proc / "123"
        self.write_identity(self.process)
        for tid in ("123", "124"):
            task = self.process / "task" / tid
            self.write_identity(task)
            (task / "fd").mkdir()
            (task / "cwd").symlink_to(self.root, target_is_directory=True)
        real_path = pathlib.Path
        paths = mock.patch.object(inspector, "Path", side_effect=lambda value:
                                  self.proc if value == "/proc" else real_path(value))
        paths.start()
        self.addCleanup(paths.stop)
        info = self.candidate.stat()
        self.directory = (info.st_dev, info.st_ino)
        directory = mock.patch.object(inspector, "directory_identity", return_value=self.directory)
        self.directory_check = directory.start()
        self.addCleanup(directory.stop)

    def write_identity(self, path, uid=1002, ticks=100):
        path.mkdir(parents=True, exist_ok=True)
        (path / "status").write_text(f"Uid:\t{uid} {uid} {uid} {uid}\n")
        (path / "stat").write_text("123 (test ) task) S " + "0 " * 18 + str(ticks) + " 0\n")

    def report(self):
        return inspector.reference_report("123", str(self.candidate), 1002)

    def test_clear_report_is_bound_and_contains_no_paths(self):
        result = self.report()
        self.assertEqual(result, {"version": 1, "pid": 123, "start_ticks": 100,
                                  "directory": list(self.directory), "status": "clear"})
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_private_thread_cwd_and_descriptor_retain_candidate(self):
        task = self.process / "task" / "124"
        for reference in (task / "cwd", task / "fd" / "3"):
            with self.subTest(reference=reference.name):
                if reference.is_symlink():
                    reference.unlink()
                reference.symlink_to(self.candidate / "file")
                self.assertEqual(self.report()["status"], "held")
                reference.unlink()
                if reference.name == "cwd":
                    reference.symlink_to(self.root)

    def test_foreign_thread_and_incomplete_fd_inventory_fail_closed(self):
        task = self.process / "task" / "124"
        self.write_identity(task, uid=1003)
        with self.assertRaises(ValueError):
            self.report()
        self.write_identity(task)
        (task / "fd").rmdir()
        with self.assertRaises(OSError):
            self.report()

    def test_changed_candidate_and_process_identity_fail_closed(self):
        self.directory_check.side_effect = [self.directory, (0, 0)]
        with self.assertRaises(ValueError):
            self.report()
        self.directory_check.side_effect = None
        original = inspector.holds_candidate

        def change_identity(reference, candidate):
            self.write_identity(self.process, ticks=200)
            return original(reference, candidate)

        with mock.patch.object(inspector, "holds_candidate", side_effect=change_identity):
            with self.assertRaises(ValueError):
                self.report()

    def test_new_thread_during_inspection_fails_closed(self):
        original = inspector.holds_candidate

        def add_thread(reference, candidate):
            self.write_identity(self.process / "task" / "125")
            return original(reference, candidate)

        with mock.patch.object(inspector, "holds_candidate", side_effect=add_thread):
            with self.assertRaises(ValueError):
                self.report()

    def test_invalid_pid_and_unsafe_candidate_are_rejected(self):
        for pid, candidate in (("0", str(self.candidate)), ("../123", str(self.candidate)),
                               ("123", "/unsafe\npath")):
            with self.subTest(pid=pid):
                with self.assertRaises(ValueError):
                    inspector.reference_report(pid, candidate, 1002)

    def test_literal_and_annotated_deleted_suffix_never_clear_a_holder(self):
        self.candidate = self.candidate.rename(self.root / "candidate (deleted)")
        task = self.process / "task" / "124"
        for reference in (task / "cwd", task / "fd" / "3"):
            for target in (str(self.candidate), str(self.candidate) + " (deleted)",
                           str(self.candidate / "file") + " (deleted)"):
                with self.subTest(reference=reference.name, target=target):
                    if reference.is_symlink():
                        reference.unlink()
                    reference.symlink_to(target)
                    self.assertEqual(self.report()["status"], "held")
                    reference.unlink()
                    if reference.name == "cwd":
                        reference.symlink_to(self.root)


class InspectCwdTests(unittest.TestCase):
    def test_candidate_must_be_canonical_directory_owned_by_invoker(self):
        candidate = pathlib.Path("/candidate")
        for uid, mode in ((1002, 0o040700), (1003, 0o040700), (1002, 0o100600)):
            info = types.SimpleNamespace(st_uid=uid, st_mode=mode, st_dev=1, st_ino=2)
            with (mock.patch.object(pathlib.Path, "resolve", return_value=candidate),
                  mock.patch.object(pathlib.Path, "lstat", return_value=info)):
                if uid == 1002 and mode == 0o040700:
                    self.assertEqual(inspector.directory_identity(candidate, 1002), (1, 2))
                else:
                    with self.assertRaises(ValueError):
                        inspector.directory_identity(candidate, 1002)
        with mock.patch.object(pathlib.Path, "resolve", return_value=pathlib.Path("/elsewhere")):
            with self.assertRaises(ValueError):
                inspector.directory_identity(candidate, 1002)

    def run_inspector(self, uid=1002, cwd="/home/operator/worktree", after_inode=12):
        output = io.StringIO()
        with (
            mock.patch.object(inspector.os, "geteuid", return_value=0),
            mock.patch.object(inspector.sys, "argv", ["inspector", "123"]),
            mock.patch.dict(inspector.os.environ, {"SUDO_UID": "1002"}),
            mock.patch.object(inspector, "owned_by_invoker", return_value=uid == 1002),
            mock.patch.object(
                inspector.os,
                "stat",
                side_effect=[types.SimpleNamespace(st_ino=12), types.SimpleNamespace(st_ino=after_inode)],
            ),
            mock.patch.object(inspector.os, "readlink", return_value=cwd),
            contextlib.redirect_stdout(output),
        ):
            result = inspector.main()
        return result, output.getvalue()

    def test_same_user_cwd_is_returned(self):
        self.assertEqual(self.run_inspector(), (0, "/home/operator/worktree\n"))

    def test_foreign_user_is_rejected(self):
        self.assertEqual(self.run_inspector(uid=1003), (1, ""))

    def test_replaced_process_is_rejected(self):
        self.assertEqual(self.run_inspector(after_inode=13), (1, ""))

    def test_control_characters_and_relative_paths_are_rejected(self):
        for cwd in ("/private\n/other", "relative/path", "/private\r/other", "/private\tother"):
            with self.subTest(cwd=cwd):
                self.assertEqual(self.run_inspector(cwd=cwd), (1, ""))

    def test_unprivileged_execution_is_rejected(self):
        with mock.patch.object(inspector.os, "geteuid", return_value=1002):
            self.assertEqual(inspector.main(), 1)

    def test_uid_fields_reject_foreign_or_malformed_identity(self):
        for values, sudo_uid in (
            (["1002", "0", "1002", "1002"], 1003),
            (["0", "0", "0", "0"], 1002),
            (["1002", "1003", "1002", "1002"], 1002),
            (["1002", "invalid", "1002", "1002"], 1002),
            (["1002", "1002", "1002"], 1002),
            ([], 1002),
        ):
            with self.subTest(values=values, sudo_uid=sudo_uid):
                self.assertFalse(inspector.uid_fields_accepted(values, sudo_uid))

    def test_uid_fields_accept_same_user_setuid_root(self):
        self.assertTrue(inspector.uid_fields_accepted(["1002", "0", "0", "1002"], 1002))

    def test_missing_uid_line_is_rejected(self):
        with mock.patch("builtins.open", mock.mock_open(read_data="Name:\tprocess\n")):
            with self.assertRaises(ValueError):
                inspector.owned_by_invoker("123", 1002)

    def test_reference_mode_emits_only_completed_report(self):
        for error in (None, PermissionError("private path must not escape")):
            with self.subTest(error=error is not None):
                output = io.StringIO()
                with (mock.patch.object(inspector.os, "geteuid", return_value=0),
                      mock.patch.dict(inspector.os.environ, {"SUDO_UID": "1002"}),
                      mock.patch.object(inspector.sys, "argv", ["inspector", "--references", "123", "/candidate"]),
                      mock.patch.object(inspector, "reference_report", return_value={"status": "clear"}, side_effect=error),
                      mock.patch.object(inspector.signal, "signal") as handler,
                      mock.patch.object(inspector.signal, "alarm") as alarm,
                      contextlib.redirect_stdout(output)):
                    result = inspector.main()
                handler.assert_called_once_with(inspector.signal.SIGALRM, inspector.signal.SIG_DFL)
                self.assertEqual(alarm.call_args_list, [mock.call(2), mock.call(0)])
                self.assertEqual(result, 1 if error else 0)
                self.assertEqual(output.getvalue(), "" if error else '{"status": "clear"}\n')


if __name__ == "__main__":
    unittest.main()
