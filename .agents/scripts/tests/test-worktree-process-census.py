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
import worktree_census_resolution as resolution
import worktree_process_attestation as attestation
import worktree_process_census as census
import worktree_process_proc as proc_observer


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


    @unittest.skipUnless(sys.platform == "linux", "Linux procfs required")
    def test_live_unknown_nondumpable_process_acquiring_worktree_is_uncertain(self):
        script = ("import ctypes,time; libc=ctypes.CDLL(None); "
                  "assert libc.prctl(15,b'node-worker',0,0,0)==0; "
                  "assert libc.prctl(4,0,0,0,0)==0; "
                  "print('ready',flush=True); "
                  "import os,sys; target=sys.stdin.readline().strip(); "
                  "os.chdir(target); fd=os.open(target,os.O_RDONLY); "
                  "print('holding',flush=True); time.sleep(30)")
        child = subprocess.Popen(  # nosec B603 -- fixed disposable non-dumpable child, no shell
            [sys.executable, "-c", script], cwd="/", stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, text=True,
            env=dict(os.environ, PWD=os.path.sep, AIDEVOPS_WORKTREE=os.path.sep))
        try:
            import select
            self.assertTrue(select.select([child.stdout], [], [], 5)[0])
            self.assertEqual(child.stdout.readline().strip(), "ready")
            time.sleep(2.1)  # Clear both second-resolution timestamp boundaries.
            with tempfile.TemporaryDirectory() as directory:
                child.stdin.write(directory + "\n")
                child.stdin.flush()
                self.assertTrue(select.select([child.stdout], [], [], 5)[0])
                self.assertEqual(child.stdout.readline().strip(), "holding")
                process = Path(f"/proc/{child.pid}")
                try:
                    os.readlink(process / "cwd")
                except PermissionError:
                    pass
                else:
                    self.skipTest("runner can inspect non-dumpable tasks")
                result = {"references": 0, "uncertain": 0, "excluded_nondumpable": 0}
                census.collect_path_references(process, directory, result)
                self.assertEqual(result, {"references": 0, "uncertain": 1,
                                          "excluded_nondumpable": 0})
                import worktree_lifetime_quiescence as quiescence
                sample = census.path_census(directory)
                self.assertFalse(quiescence.empty_census(sample, sample.get("boot_id")))
        finally:
            child.terminate()
            child.wait(timeout=5)
            child.stdin.close()
            child.stdout.close()

    def test_unreadable_tasks_are_uncertain_regardless_of_comm(self):
        with tempfile.TemporaryDirectory() as directory:
            process = Path(directory)
            task = process / "task" / "100"
            task.mkdir(parents=True)
            (task / "status").write_text("Uid:\t" + "\t".join([str(os.getuid())] * 4) + "\n")
            for name, error, excluded in (
                    ("ssh-agent", PermissionError(), False),
                    ("gpg-agent", PermissionError(), False),
                    ("(sd-pam)", PermissionError(), False),
                    ("systemd", PermissionError(), False),
                    ("ssh-agent", OSError(), False),
                    ("sshd", PermissionError(), False),
                    ("python3", PermissionError(), False),
                    ("node-worker", PermissionError(), False)):
                (task / "stat").write_text(f"100 ({name}) " + " ".join(["S"] + ["0"] * 19))
                result = {"references": 0, "uncertain": 0, "excluded_nondumpable": 0}
                with self.subTest(name=name, error=error), \
                        patch.object(census, "inspect_path_references", side_effect=error):
                    census.collect_path_references(process, "/worktree", result)
                    self.assertEqual(result["excluded_nondumpable"], int(excluded))
                    self.assertEqual(result["uncertain"], int(not excluded))
                    self.assertEqual(result["references"], 0)

    @unittest.skipUnless(sys.platform == "linux", "Linux procfs required")
    def test_census_rejects_mismatched_or_replaced_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            sample = census.path_census(directory, source_inode="wrong-generation")
            self.assertEqual(sample["status"], "unavailable")
            with patch.object(census.owner, "inode", side_effect=["original", "replacement"]):
                sample = census.path_census(directory, source_inode="original")
                self.assertEqual(sample["status"], "unavailable")

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


class ModelledSessionProc(unittest.TestCase):
    """Modelled kernel facts for GH#38428: only unforgeable facts attest a task."""

    # A fixed unprivileged census user keeps the model host-independent (root CI too).
    UID = "4242"
    MANAGER_CGROUP = f"0::/user.slice/user-{UID}.slice/user@{UID}.service/init.scope\n"

    def setUp(self):
        real_stat = os.stat

        def hidden_executable(path, *args, **kwargs):
            # Non-dumpable managers hide their executable, as on systemd 254+.
            if Path(path).name == "exe":
                raise PermissionError()
            return real_stat(path, *args, **kwargs)

        for name, kwargs in (("stat", {"side_effect": hidden_executable}),
                             ("getuid", {"return_value": int(self.UID)})):
            patcher = patch.object(attestation.os, name, **kwargs)
            patcher.start()
            self.addCleanup(patcher.stop)
        # PID 1's record of user@UID.service; tests change it to model absence.
        self.main_pid = patch.object(attestation, "user_manager_main_pid", return_value="91")
        self.main_pid.start()
        self.addCleanup(self.main_pid.stop)
        self.build()

    def build(self):
        """Create a fresh modelled /proc holding the reported session tasks."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.proc = Path(temporary.name)
        (self.proc / "self").mkdir()
        (self.proc / "self" / "uid_map").write_text("0 0 4294967295\n")
        patcher = patch.object(attestation, "PROC", self.proc)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.task(1, name="systemd", ppid=0, flags=0x100, start=1, uids="0")
        self.task(91, name="systemd", ppid=1, flags=0x400100, start=1000, caps="800000000",
                  cgroup=self.MANAGER_CGROUP, children="92 140")
        self.task(92, name="(sd-pam)", ppid=91, flags=0x400140, start=1001)
        self.task(117, name="sshd", ppid=1, flags=0x400100, start=1500, uids="0", caps="1ffffffffff")
        self.task(128, name="sshd", ppid=117, flags=0x400140, start=1600)

    def task(self, pid, **facts):
        """Write one task's stat, status, cgroup, uid_map and children files."""
        facts = {"uids": self.UID, "caps": "0", "cgroup": "0::/\n", "children": "",
                 "uid_map": "0 0 4294967295\n", **facts}
        process = self.proc / str(pid)
        task = process / "task" / str(pid)
        task.mkdir(parents=True, exist_ok=True)
        fields = (["S", str(facts["ppid"]), "0", "0", "0", "0", str(facts["flags"])]
                  + ["0"] * 12 + [str(facts["start"])])
        status = (f"Name:\t{facts['name']}\nUid:\t" + "\t".join([facts["uids"]] * 4)
                  + f"\nCapEff:\t{facts['caps']}\nCapPrm:\t{facts['caps']}\n")
        for directory in (process, task):
            (directory / "stat").write_text(f"{pid} ({facts['name']}) " + " ".join(fields) + "\n")
            (directory / "status").write_text(status)
        (process / "cgroup").write_text(facts["cgroup"])
        (process / "uid_map").write_text(facts["uid_map"])
        (task / "children").write_text(facts["children"])
        return task

    def attest(self, pid):
        return attestation.attested_session_class(self.proc / str(pid) / "task" / str(pid))


class SessionAttestationTests(ModelledSessionProc):
    """The census predicate itself."""

    def test_reported_session_tasks_are_attested(self):
        self.assertEqual(self.attest(91), "user-manager")
        self.assertEqual(self.attest(92), "pam-session-keeper")
        self.assertEqual(self.attest(128), "privsep-session")

    def test_root_census_never_attests(self):
        # Root could forge any root-owned fact, so attestation needs an unprivileged user.
        with patch.object(attestation.os, "getuid", return_value=0):
            self.assertIsNone(self.attest(128))

    def test_spoofable_or_unproven_session_lookalikes_stay_uncertain(self):
        ticks = attestation.PAM_KEEPER_START_WINDOW_SECONDS * os.sysconf("SC_CLK_TCK")
        cases = {
            # User-renamed processes: comm and parentage alone prove nothing.
            # A user can move an orphan into its delegated init.scope cgroup and
            # exec any root-owned binary under the name "systemd" (GH#38428 review).
            "manager lookalike PID 1 did not start": dict(pid=95, name="systemd", ppid=1,
                                                          flags=0x400100, start=1000,
                                                          caps="800000000",
                                                          cgroup=self.MANAGER_CGROUP),
            "manager in child user namespace": dict(pid=91, name="systemd", ppid=1, flags=0x400100,
                                                    start=1000, caps="800000000",
                                                    cgroup=self.MANAGER_CGROUP, uid_map="0 1000 1\n"),
            "manager that never exec'd": dict(pid=91, name="systemd", ppid=1, flags=0x400140,
                                              start=1000, caps="800000000", cgroup=self.MANAGER_CGROUP),
            "first child of a lookalike manager": dict(pid=96, name="(sd-pam)", ppid=95,
                                                       flags=0x400140, start=1001),
            "keeper that is not the first child": dict(pid=140, name="(sd-pam)", ppid=91,
                                                       flags=0x400140, start=1001),
            "keeper outside the start window": dict(pid=93, name="(sd-pam)", ppid=91, flags=0x400140,
                                                    start=1001 + ticks, children=""),
            "exec'd keeper": dict(pid=92, name="(sd-pam)", ppid=91, flags=0x400100, start=1001),
            "keeper with capabilities": dict(pid=92, name="(sd-pam)", ppid=91, flags=0x400140,
                                             start=1001, caps="1"),
            "sshd-named child of user process": dict(pid=129, name="sshd", ppid=128, flags=0x400140,
                                                     start=1700),
            "exec'd privsep child": dict(pid=128, name="sshd", ppid=117, flags=0x400100, start=1600),
            "child predating reused parent pid": dict(pid=128, name="sshd", ppid=117, flags=0x400140,
                                                      start=1400),
            "orphan adopted by init": dict(pid=138, name="ssh-agent", ppid=1, flags=0x400140, start=2000),
        }
        for label, case in cases.items():
            with self.subTest(case=label):
                self.build()
                pid = case.pop("pid")
                self.task(pid, **case)
                if pid == 93:
                    (self.proc / "91" / "task" / "91" / "children").write_text("93 92")
                if pid == 96:
                    self.task(95, name="systemd", ppid=1, flags=0x400100, start=1000,
                              caps="800000000", cgroup=self.MANAGER_CGROUP, children="96")
                self.assertIsNone(self.attest(pid))

    def test_unknown_system_manager_record_or_namespace_leaves_tasks_uncertain(self):
        self.main_pid.stop()
        with patch.object(attestation, "user_manager_main_pid", return_value=None):
            self.assertIsNone(self.attest(91))
            self.assertIsNone(self.attest(92))
        self.main_pid.start()
        # Inside a user namespace, root-owned and UID facts are the namespace's own.
        (self.proc / "self" / "uid_map").write_text("0 4242 1\n")
        for pid in (91, 92, 128):
            with self.subTest(pid=pid):
                self.assertIsNone(self.attest(pid))
        (self.proc / "self" / "uid_map").write_text("0 0 4294967295\n")
        (self.proc / "117" / "uid_map").write_text("0 100000 65536\n")
        self.assertIsNone(self.attest(128))
        # Another PID 1 (e.g. a container with the host bus) names foreign PIDs.
        self.task(1, name="tini", ppid=0, flags=0x100, start=1, uids="0")
        self.assertIsNone(self.attest(91))
        self.assertIsNone(self.attest(92))

    def test_system_manager_record_must_agree_and_answer(self):
        self.main_pid.stop()
        self.addCleanup(self.main_pid.start)
        answers = {"MainPID and ExecMainPID agree": ("91\n91\n", 0, "91"),
                   "MainPID repointed by notification": ("140\n91\n", 0, None),
                   "no main process": ("0\n0\n", 0, None),
                   "one property missing": ("91\n", 0, None),
                   "systemctl failed": ("", 1, None),
                   "systemctl timed out": (subprocess.TimeoutExpired("systemctl", 5), 0, None)}
        with patch.object(attestation, "_root_owned_file", return_value=True):
            for label, (stdout, code, expected) in answers.items():
                with self.subTest(case=label):
                    effect = stdout if isinstance(stdout, Exception) else None
                    reply = subprocess.CompletedProcess([], code, stdout if effect is None else "", "")
                    with patch.object(attestation.subprocess, "run", return_value=reply,
                                      side_effect=effect) as run:
                        self.assertEqual(attestation.user_manager_main_pid(self.UID), expected)
                    self.assertEqual(run.call_args.kwargs["env"], {})

    def test_attested_and_uncertain_tasks_are_counted_by_class(self):
        self.task(138, name="ssh-agent", ppid=1, flags=0x400140, start=2000)
        result = {"references": 0, "uncertain": 0, "excluded_nondumpable": 0,
                  "uncertain_classes": census.Counter(), "excluded_nondumpable_classes": census.Counter()}
        with patch.object(census, "inspect_path_references", side_effect=PermissionError()):
            for pid in (91, 92, 128, 138):
                census.collect_path_references(self.proc / str(pid), "/worktree", result)
        self.assertEqual(result["uncertain"], 1)
        self.assertEqual(dict(result["uncertain_classes"]), {"nondumpable": 1})
        self.assertEqual(dict(result["excluded_nondumpable_classes"]),
                         {"pam-session-keeper": 1, "privsep-session": 1, "user-manager": 1})


class ObserverAttestationTests(ModelledSessionProc):
    """GH#39034: the removal-guard observer shares the census attestation."""

    def observe(self, enabled=True):
        """Run both observer entry points over the modelled proc (no cwd links)."""
        with patch.object(proc_observer, "attestation_enabled", return_value=enabled):
            _, denied = proc_observer.collect(self.proc)
            with os.scandir(self.proc) as entries:
                lines = sorted(proc_observer.cwd_map_line(entry, enabled) for entry in entries
                               if entry.name.isdigit())
        return sorted(int(process.name) for process in denied), lines

    def test_attested_session_tasks_are_excluded_and_others_stay_denied(self):
        # An unattested gpg-agent-like orphan and a forged re-parented "systemd"
        # chain (lookalike manager PID 1 did not start, plus its first child).
        self.task(138, name="gpg-agent", ppid=1, flags=0x400140, start=2000)
        self.task(95, name="systemd", ppid=1, flags=0x400100, start=1000, caps="800000000",
                  cgroup=self.MANAGER_CGROUP, children="96")
        self.task(96, name="(sd-pam)", ppid=95, flags=0x400140, start=1001)
        denied, lines = self.observe()
        self.assertEqual(denied, [95, 96, 138])
        self.assertEqual(lines, ["F\t138", "F\t95", "F\t96", "S\t1", "S\t117",
                                 "S\t128", "S\t91", "S\t92"])

    def test_disabled_attestation_or_unattested_thread_keeps_tasks_denied(self):
        denied, lines = self.observe(enabled=False)
        self.assertEqual(denied, [91, 92, 128])
        self.assertIn("F\t91", lines)
        # A second, unattested thread (e.g. an exec'd task) denies the process.
        thread = self.proc / "128" / "task" / "130"
        thread.mkdir()
        (thread / "stat").write_text("130 (sshd) S 117 0 0 0 0 4194560 " + "0 " * 12 + "1600\n")
        (thread / "status").write_text((self.proc / "128" / "status").read_text())
        denied, _ = self.observe()
        self.assertEqual(denied, [128])

    def test_attestation_requires_the_attestation_root_and_proc_visibility(self):
        with patch.object(proc_observer.sys, "platform", "linux"):
            with patch.object(proc_observer, "require_proc_visibility"):
                self.assertTrue(proc_observer.attestation_enabled(self.proc))
                self.assertFalse(proc_observer.attestation_enabled(self.proc / "other"))
            with patch.object(proc_observer, "require_proc_visibility",
                              side_effect=ValueError("filtered proc mount")):
                self.assertFalse(proc_observer.attestation_enabled(self.proc))
        with patch.object(proc_observer.sys, "platform", "darwin"):
            self.assertFalse(proc_observer.attestation_enabled(self.proc))


class PrivilegedCensusTests(unittest.TestCase):
    """The opt-in root census resolves uncertainty but never hides a reference."""

    @staticmethod
    def sample(references=0, uncertain=3):
        return {"status": "available", "references": references, "uncertain": uncertain,
                "excluded_nondumpable": 0, "uncertain_classes": census.Counter({"nondumpable": uncertain}),
                "excluded_nondumpable_classes": census.Counter()}

    @staticmethod
    def protected_proc():
        sys.path.insert(0, str(Path(census.__file__).resolve().parent.parent / "worker-lifecycle"))
        try:
            from worker_lifecycle import protected_proc
        finally:
            sys.path.pop(0)
        return protected_proc

    def apply(self, result, report=None, error=None):
        with patch.object(self.protected_proc(), "privileged_path_census", return_value=report,
                          side_effect=error) as call:
            resolution.apply_privileged_census("/worktree", result)
            return call

    def test_clear_held_and_unavailable_reports(self):
        result = self.sample()
        self.apply(result, {"references": 0, "uncertain": 0})
        self.assertEqual((result["references"], result["uncertain"], result["privileged_census"]),
                         (0, 0, "clear"))
        result = self.sample()
        self.apply(result, {"references": 1, "uncertain": 0})
        self.assertEqual((result["references"], result["privileged_census"]), (1, "held"))
        result = self.sample()
        self.apply(result, {"references": 0, "uncertain": 2})
        self.assertEqual(dict(result["uncertain_classes"]), {"privileged": 2})
        result = self.sample()
        refusal = self.protected_proc().ProcessCensusUnavailable(0, 0, "census", "inspection-not-enabled")
        self.apply(result, error=refusal)
        self.assertEqual((result["uncertain"], result["privileged_census"]), (3, "inspection-not-enabled"))

    def test_privilege_is_not_requested_without_uncertainty_or_after_a_reference(self):
        for result in (self.sample(uncertain=0), self.sample(references=1)):
            call = self.apply(result, {"references": 0, "uncertain": 0})
            call.assert_not_called()
            self.assertNotIn("privileged_census", result)

    def test_refusal_detail_names_classes_without_paths(self):
        sample = self.sample()
        sample.update(privileged_census="inspection-not-enabled",
                      excluded_nondumpable_classes={"user-manager": 1})
        detail = resolution.describe_census(sample)
        self.assertEqual(detail, "status=available references=0 uncertain=3(nondumpable=3) "
                                 "excluded_nondumpable=0(user-manager=1) "
                                 "privileged_census=inspection-not-enabled")
        self.assertEqual(resolution.describe_census(None), "census unavailable")


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
