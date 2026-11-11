"""Native retirement process census dispatch and macOS field parsing."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from worker_lifecycle import legacy_proc, legacy_proc_macos, protected_proc, retirement
from worker_lifecycle.cleanup_failure import failure_details
from worker_lifecycle.cli_errors import error_details


class RetirementProcesses(unittest.TestCase):
    def test_retirement_boundaries_census_actual_location_before_opening_handles(self):
        public = Path("/work/public")
        plan = {"container": "/work/private", "git_directory": "/repo/admin",
                "generation_id": "fixture"}
        for boundary, expected in (
            (retirement._relocate_source, public),
            (retirement._remove_private, Path("/work/private/tree")),
        ):
            for reason in ("live-process-reference", "proc-observation-unavailable"):
                with self.subTest(boundary=boundary.__name__, reason=reason):
                    with patch.object(retirement, "DirectoryHandle") as handle:
                        with patch.object(retirement, "require_idle_processes",
                                          side_effect=ValueError(reason)) as census:
                            with self.assertRaisesRegex(ValueError, reason):
                                boundary(None, public, plan, {})
                            census.assert_called_once_with(expected)
                            handle.assert_not_called()

    def observe(self, output, *, code=0, stderr=b""):
        result = subprocess.CompletedProcess([], code, output, stderr)
        with patch.object(legacy_proc_macos.subprocess, "run", return_value=result):
            legacy_proc_macos.require_idle_macos(Path("/work/tree with\nnewline"))

    def census(self, name=b"/outside"):
        return (b"p" + str(os.getpid()).encode() + b"\0\nfcwd\0n/elsewhere\0\n"
                + b"f3\0n" + name + b"\0\n")

    def test_idle_macos_census(self):
        self.observe(self.census())

    def test_macos_open_file_and_cwd_retain_tree(self):
        for descriptor in (b"3", b"cwd"):
            with self.subTest(descriptor=descriptor):
                output = self.census() + b"f" + descriptor + b"\0n/work/tree with\nnewline/file\0\n"
                with self.assertRaisesRegex(ValueError, "live-process-reference"):
                    self.observe(output)

    def test_macos_partial_empty_or_failed_observation_fails_closed(self):
        for output, code, stderr in (
            (b"", 0, b""),
            (b"p123\0\nf3\0n/outside\0\n", 0, b""),
            (self.census(), 1, b""),
            (self.census(), 0, b"warning"),
        ):
            with self.subTest(output=output, code=code, stderr=stderr):
                with self.assertRaisesRegex(ValueError, "proc-observation-unavailable"):
                    self.observe(output, code=code, stderr=stderr)

    def test_macos_unavailable_binary_fails_closed(self):
        with patch.object(legacy_proc_macos.subprocess, "run", side_effect=FileNotFoundError):
            with self.assertRaisesRegex(ValueError, "proc-observation-unavailable"):
                legacy_proc_macos.require_idle_macos(Path("/work/tree"))

    def test_native_dispatch(self):
        path = Path("/work/tree")
        for system, name in (("Linux", "require_idle_proc"), ("Darwin", "require_idle_macos")):
            with self.subTest(system=system):
                with patch.object(legacy_proc.platform, "system", return_value=system):
                    with patch.object(legacy_proc, name) as observer:
                        legacy_proc.require_idle_processes(path)
                        observer.assert_called_once_with(path)
        with patch.object(legacy_proc.platform, "system", return_value="unknown"):
            with self.assertRaisesRegex(ValueError, "proc-observation-unavailable"):
                legacy_proc.require_idle_processes(path)


@unittest.skipUnless(sys.platform == "linux", "Linux reference inspector adapter")
class ProtectedProcesses(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.candidate = Path(temporary.name)
        self.process = Path("/proc") / str(os.getpid())
        self.task = self.process / "task" / str(os.getpid())
        directory = self.candidate.stat()
        start = int((self.process / "stat").read_text().rsplit(")", 1)[1].split()[19])
        self.report = {"version": 1, "pid": os.getpid(), "start_ticks": start,
                       "directory": [directory.st_dev, directory.st_ino], "status": "clear"}

    def observe(self, report=None, *, output=None, code=0, stderr=b"", error=None):
        output = json.dumps(self.report if report is None else report).encode() if output is None else output
        result = subprocess.CompletedProcess([], code, output, stderr)
        with (patch.object(protected_proc, "_allowed", return_value=True),
              patch.object(protected_proc, "_trusted_executable", return_value=True),
              patch.object(protected_proc, "SUDO", Path(sys.executable)),
              patch.object(protected_proc.subprocess, "run", return_value=result, side_effect=error) as run):
            protected_proc.require_protected_references(self.candidate, self.task, Path("/proc"))
            return run.call_args

    def test_bound_clear_evidence_and_noninteractive_fixed_command(self):
        call = self.observe()
        self.assertEqual(call.args[0][1:], ["-n", "--", str(protected_proc.INSPECTOR),
                                          "--references", str(os.getpid()), str(self.candidate)])
        self.assertEqual(call.kwargs["env"], {"PATH": "/usr/bin:/bin", "LANG": "C"})
        self.assertEqual(call.kwargs["timeout"], 3)

    def test_positive_reference_is_not_accepted(self):
        with self.assertRaisesRegex(ValueError, "live-process-reference"):
            self.observe({**self.report, "status": "held"})

    def test_literal_and_annotated_deleted_suffix_references_retain_tree(self):
        candidate = Path("/work/candidate (deleted)")
        for reference in (str(candidate), str(candidate) + " (deleted)",
                          str(candidate / "file") + " (deleted)"):
            with patch.object(legacy_proc.os, "readlink", return_value=reference):
                with self.assertRaisesRegex(ValueError, "live-process-reference"):
                    legacy_proc.require_idle_reference(candidate, Path("/reference"))

    def test_process_and_candidate_replacement_reject_fresh_looking_report(self):
        original = Path.stat
        for changed in (self.process, self.candidate):
            count = 0

            def replaced(path, *args, changed=changed, **kwargs):
                nonlocal count
                info = original(path, *args, **kwargs)
                if path == changed:
                    count += 1
                    return SimpleNamespace(st_dev=info.st_dev, st_ino=info.st_ino + (count > 1))
                return info

            with patch.object(Path, "stat", autospec=True, side_effect=replaced):
                with self.assertRaisesRegex(ValueError, "proc-observation-unavailable"):
                    self.observe()

    def test_partial_stale_malformed_and_legacy_output_fail_closed(self):
        for report in ([], {}, {**self.report, "pid": 0},
                       {**self.report, "start_ticks": -1}, {**self.report, "version": True},
                       {**self.report, "directory": [0, 0]}, {**self.report, "status": "unknown"},
                       {**self.report, "extra": "untrusted"}):
            with self.subTest(report=report):
                with self.assertRaisesRegex(ValueError, "proc-observation-unavailable"):
                    self.observe(report)
        for output, code, stderr in ((b"", 0, b""), (b"/legacy/cwd\n", 0, b""),
                                     (b"x" * 4097, 0, b""), (b"{}", 1, b""),
                                     (json.dumps(self.report).encode(), 0, b"warning")):
            with self.subTest(code=code, stderr=bool(stderr)):
                with self.assertRaisesRegex(ValueError, "proc-observation-unavailable"):
                    self.observe(output=output, code=code, stderr=stderr)
        with self.assertRaisesRegex(ValueError, "proc-observation-unavailable"):
            self.observe(error=subprocess.TimeoutExpired("inspector", 3))

    def test_default_opt_out_never_invokes_privilege(self):
        with (patch.dict(os.environ, {}, clear=True),
              patch.object(protected_proc.subprocess, "run") as run):
            with self.assertRaises(protected_proc.ProcessCensusUnavailable):
                protected_proc.require_protected_references(self.candidate, self.task, Path("/proc"))
            run.assert_not_called()

    def test_nixos_and_maintenance_remain_unprivileged(self):
        with patch.dict(os.environ, {protected_proc.OPT_IN: "1"}, clear=True):
            for release, expected in (('ID="nixos"\n', False), ("ID=ubuntu\n", True), ("", False)):
                with patch.object(Path, "read_text", return_value=release):
                    self.assertEqual(protected_proc._allowed(), expected)
            for key in ("AIDEVOPS_WORKTREE_MAINTENANCE_PLAN", "AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM"):
                with patch.dict(os.environ, {key: "1"}):
                    self.assertFalse(protected_proc._allowed())

    def test_executable_and_every_ancestor_require_root_ownership_and_no_write_access(self):
        executable = Path("/trusted/inspector")
        for case in ("trusted", "file-write", "parent-write", "file-owner", "parent-owner"):
            def info(item, case=case):
                is_file = item == executable
                uid = 1002 if ((case == "file-owner" and is_file)
                               or (case == "parent-owner" and item == executable.parent)) else 0
                mode = 0o100755 if is_file else 0o040755
                if (case == "file-write" and is_file) or (case == "parent-write" and item == executable.parent):
                    mode |= 0o020
                return SimpleNamespace(st_uid=uid, st_mode=mode)

            with (patch.object(Path, "resolve", return_value=executable),
                  patch.object(Path, "lstat", autospec=True, side_effect=info),
                  patch.object(protected_proc.os, "access", return_value=True)):
                self.assertEqual(protected_proc._trusted_executable(executable), case == "trusted")
        with patch.object(Path, "resolve", return_value=Path("/elsewhere")):
            self.assertFalse(protected_proc._trusted_executable(executable))

    def test_untrusted_inspector_never_executes(self):
        with (patch.object(protected_proc, "_allowed", return_value=True),
              patch.object(protected_proc, "SUDO", Path(sys.executable)),
              patch.object(protected_proc, "_trusted_executable", return_value=False),
              patch.object(protected_proc.subprocess, "run") as run):
            with self.assertRaises(protected_proc.ProcessCensusUnavailable):
                protected_proc.require_protected_references(self.candidate, self.task, Path("/proc"))
            run.assert_not_called()
        self.assertFalse(protected_proc._trusted_executable(self.candidate))

    def test_cwd_denial_reports_actual_observer_without_paths(self):
        refusal = ValueError("proc-observation-unavailable")
        refusal.__cause__ = ValueError("daemon-not-older")
        error = protected_proc.ProcessCensusUnavailable(os.getpid(), os.getpid(), "references", "inspection-not-enabled")
        with (patch.object(legacy_proc.os, "readlink", side_effect=PermissionError("private path")),
              patch.object(legacy_proc, "require_predating_daemon", side_effect=refusal),
              patch.object(legacy_proc, "require_protected_references", side_effect=error)):
            with self.assertRaises(protected_proc.ProcessCensusUnavailable) as caught:
                legacy_proc.inspect_proc_references(self.candidate, self.task, Path("/proc"))
        details = error_details(caught.exception, "cleanup-worktree")
        self.assertEqual(details["reason"], "ValueError")
        self.assertEqual(details["detail"], "proc-observation-unavailable")
        self.assertEqual(details["process_observation"]["stage"], "cwd")
        self.assertEqual(details["process_observation"]["daemon_cause"], "daemon-not-older")
        self.assertNotIn(str(self.candidate), json.dumps(details))
        bulk = failure_details(caught.exception)
        self.assertEqual(bulk["reason"], "proc-observation-unavailable")
        self.assertEqual(bulk["process_observation"], details["process_observation"])
