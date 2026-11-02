#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Linux path-census coverage extracted from the owner lifetime suite."""

import os
from pathlib import Path
import subprocess  # nosec B404 -- tests spawn fixed fixture processes only
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


    def test_only_permission_denied_old_allowlisted_tasks_are_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            process = Path(directory)
            task = process / "task" / "100"
            task.mkdir(parents=True)
            (task / "status").write_text("Uid:\t" + "\t".join([str(os.getuid())] * 4) + "\n")
            for name, start, error, birth, excluded in (
                    ("ssh-agent", 100, PermissionError(), 110, 1),
                    ("gpg-agent", 100, PermissionError(), 110, 1),
                    ("(sd-pam)", 100, PermissionError(), 110, 1),
                    ("systemd", 100, PermissionError(), 110, 1),
                    ("sshd", 100, PermissionError(), 110, 1),
                    ("dbus-daemon", 100, PermissionError(), 110, 1),
                    ("ssh-agent", 1100, PermissionError(), 110, 0),
                    ("ssh-agent", 900, PermissionError(), 110, 0),
                    ("python3", 100, PermissionError(), 110, 0),
                    ("ssh-agent", 100, OSError(), 110, 0),
                    ("ssh-agent", 100, PermissionError(), None, 0),
                    ("ssh-agent", 0, PermissionError(), 110, 0),
                    ("ssh-agent", "bad", PermissionError(), 110, 0)):
                fields = ["S"] + ["0"] * 18 + [str(start)]
                stat = f"100 ({name}) " + " ".join(fields)
                (task / "stat").write_text(stat)
                result = {"references": 0, "uncertain": 0, "excluded_nondumpable": 0}
                original_read = Path.read_text

                def read_text(path, *args, **kwargs):
                    if path == Path("/proc/stat"):
                        return "btime 100\n"
                    return original_read(path, *args, **kwargs)

                with self.subTest(name=name, start=start, error=error, birth=birth), \
                        patch.object(census, "inspect_path_references", side_effect=error), \
                        patch.object(Path, "read_text", read_text), \
                        patch.object(os, "sysconf", return_value=100):
                    census.collect_path_references(process, "/worktree", result, birth)
                    self.assertEqual(result["excluded_nondumpable"], excluded)
                    self.assertEqual(result["uncertain"], 1 - excluded)
                    self.assertEqual(result["references"], 0)

    def test_birth_time_requires_same_inode_and_never_uses_ctime(self):
        with tempfile.TemporaryDirectory() as directory:
            observed = os.stat(directory)
            identity = f"{observed.st_dev}:{observed.st_ino}"
            for output, expected in ((f"{identity} 100", 100), (f"{identity} 0", None),
                                     ("1:2 100", None), ("bad", None),
                                     (f"{identity} 999999999999", None)):
                with self.subTest(output=output), \
                        patch.object(subprocess, "check_output", return_value=output):
                    self.assertEqual(census.worktree_birth(directory), expected)
            with patch.object(subprocess, "check_output", side_effect=FileNotFoundError()):
                self.assertIsNone(census.worktree_birth(directory))

    def test_daemon_generation_change_is_not_excluded(self):
        stat = "100 (ssh-agent) S " + "0 " * 18 + "100"
        for values in ([stat, "btime 100\n", stat.replace("100", "200")],
                       [stat, "missing boot time"], ["malformed"]):
            with self.subTest(values=values), patch.object(Path, "read_text", side_effect=values), \
                    patch.object(os, "sysconf", return_value=100):
                self.assertFalse(census.predates_worktree(Path("/proc/100"), 110))

    def test_exclusion_counts_do_not_relax_quiescence(self):
        import worktree_lifetime_quiescence as quiescence
        sample = {"status": "available", "boot_id": "boot", "uid": os.getuid(),
                  "observed_at": time.time(), "references": 0, "uncertain": 0,
                  "excluded_nondumpable": 4}
        self.assertTrue(quiescence.empty_census(sample, "boot"))
        sample["uncertain"] = 1
        self.assertFalse(quiescence.empty_census(sample, "boot"))
        sample.update(uncertain=0, references=1)
        self.assertFalse(quiescence.empty_census(sample, "boot"))


class ProcessSnapshotTests(unittest.TestCase):
    def snapshot(self):
        return {"status": "available", "boot_id": "11111111-1111-1111-1111-111111111111",
                "processes": {100: {"start": "10", "state": "S", "cgroup": "/user/aidevops-worker-one.service"}},
                "uncertain_pids": [], "membership_unavailable": False}

    def managed(self):
        return {"manager": "pulse", "created_by": {"entrypoint": "pulse"}, "state": "running",
                "launches": [{"unit": "aidevops-worker-one", "invocation": "a" * 32,
                              "boot_id": self.snapshot()["boot_id"],
                              "cgroup": "/user/aidevops-worker-one.service"}]}

    def test_snapshot_distinguishes_process_identity_absence_and_uncertainty(self):
        import worktree_lifetime_owner as owner
        import worktree_process_snapshot as census
        snapshot = self.snapshot()
        launch = {"kind": owner.KIND, "owner_pid": 100, "owner_start": "10",
                  "boot_id": snapshot["boot_id"]}
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "same-process-alive")
        launch["owner_start"] = "20"
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "pid-reused")
        snapshot["processes"].clear()
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "pid-absent")
        snapshot["uncertain_pids"] = [100]
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "unknown")
        snapshot["status"] = "unavailable"
        self.assertEqual(census.recorded_status(launch, snapshot)["status"], "unknown")

    def test_empty_or_failed_process_listing_is_unavailable(self):
        import worktree_process_snapshot as census
        for output in ("", "malformed"):
            with self.subTest(output=output), patch.object(subprocess, "check_output", return_value=output):
                self.assertEqual(census.capture()["status"], "unavailable")

    def test_managed_activity_uses_processes_not_retained_unit_objects(self):
        import worktree_process_snapshot as census
        snapshot, record = self.snapshot(), self.managed()
        self.assertEqual(census.activity(record, snapshot)["state"], "active")
        snapshot["processes"][100]["cgroup"] += "/child"
        self.assertEqual(census.activity(record, snapshot)["state"], "active")
        snapshot["processes"][100]["cgroup"] = "/user/aidevops-worker-one.service-other"
        self.assertEqual(census.activity(record, snapshot)["state"], "not-observed")
        self.assertFalse(census.activity(record, snapshot)["deletion_authorized"])

    def test_unknown_admission_membership_and_provenance_do_not_become_idle(self):
        import worktree_process_snapshot as census
        snapshot, record = self.snapshot(), self.managed()
        snapshot["processes"].clear()
        snapshot["membership_unavailable"] = True
        self.assertEqual(census.activity(record, snapshot)["state"], "unknown")
        snapshot["membership_unavailable"] = False
        snapshot["runtime_inspection_unavailable"] = [200]
        self.assertEqual(census.activity(record, snapshot)["state"], "unknown")
        snapshot["runtime_inspection_unavailable"] = []
        record["launches"][0]["invocation"] = None
        self.assertEqual(census.activity(record, snapshot)["state"], "unknown")
        record["manager"] = "owner-cgroup"
        self.assertEqual(census.activity(record, snapshot)["reason"], "pulse-management-unrecorded")

    def test_runtime_directory_positive_match_protects_legacy_without_enrollment(self):
        import worktree_process_snapshot as census
        arguments = ["bash", "/agents/scripts/headless-runtime-helper.sh", "run",
                     "--role", "worker", "--dir", "/worktree", "--prompt", "never-report-this"]
        self.assertEqual(census.worker_directory(arguments), "/worktree")
        arguments[4] = "pulse"
        self.assertIsNone(census.worker_directory(arguments))
        snapshot = self.snapshot()
        snapshot["processes"][100]["worker_worktree"] = "/worktree"
        record = {"manager": "owner-cgroup", "identity": {"path": "/worktree"}}
        self.assertEqual(census.activity(record, snapshot)["state"], "active")
        self.assertEqual(record["manager"], "owner-cgroup")

    def test_malformed_managed_identities_remain_unknown(self):
        import worktree_process_snapshot as census
        snapshot = self.snapshot()
        snapshot["processes"].clear()
        cases = (("launch", "boot_id", "invalid"), ("launch", "invocation", "invalid"),
                 ("launch", "unit", []), ("launch", "cgroup", "relative/aidevops-worker-one.service"),
                 ("launch", "cgroup", "/user/./aidevops-worker-one.service"),
                 ("launch", "cgroup", "//user/aidevops-worker-one.service"),
                 ("record", "identity", []), ("record", "identity", False),
                 ("record", "identity", 0), ("record", "identity", ""), ("record", "identity", None))
        for scope, key, value in cases:
            record = self.managed()
            targets = {"launch": record["launches"][0], "record": record}
            targets[scope][key] = value
            with self.subTest(scope=scope, key=key, value=value):
                self.assertEqual(census.activity(record, snapshot)["state"], "unknown")


if __name__ == "__main__":
    unittest.main()
