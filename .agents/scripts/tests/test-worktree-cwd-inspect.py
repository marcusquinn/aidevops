#!/usr/bin/env python3
"""Fail-closed contract for the optional privileged CWD inspector."""

import contextlib
import importlib.util
import io
import pathlib
import types
import unittest
from unittest import mock


INSPECTOR_PATH = pathlib.Path(__file__).resolve().parents[1] / "worktree-cwd-inspect.py"
SPEC = importlib.util.spec_from_file_location("worktree_cwd_inspect", INSPECTOR_PATH)
assert SPEC is not None and SPEC.loader is not None
inspector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inspector)


class InspectCwdTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
