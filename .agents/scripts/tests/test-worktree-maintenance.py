#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Maintenance authorization is distinct from missing historical completion."""

import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import worktree_maintenance_boundary as boundary

SPEC = importlib.util.spec_from_file_location("maintenance", SCRIPTS / "worktree-maintenance.py")
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)


class MaintenanceBoundaryTests(unittest.TestCase):
    def snapshot(self):
        return {"LoadState": "loaded", "ActiveState": "active", "User": "1000",
                "KillMode": "control-group", "Restart": "no", "FragmentPath": "/trusted/unit",
                "Conflicts": "user@1000.service", "Before": "user@1000.service",
                "ControlGroup": "/system.slice/fixture.service", "InvocationID": "a" * 32}

    def observe(self, snapshot=None, user="inactive", rescue="active", exclusive=None):
        value = snapshot or self.snapshot()
        def unit(name):
            if name.startswith("aidevops-"):
                return value.copy()
            return {"ActiveState": user if name == "user@1000.service" else rescue}
        with patch.object(boundary.sys, "platform", "linux"), patch.object(os, "getuid", return_value=1000), \
                patch.object(boundary, "system_unit", side_effect=unit), \
                patch.object(boundary, "root_controlled"), \
                patch.object(boundary, "process_group", return_value=value["ControlGroup"]), \
                patch.object(boundary, "require_exclusive_user", side_effect=exclusive), \
                patch.dict(os.environ, {"INVOCATION_ID": "a" * 32}):
            return boundary.observe()

    def test_valid_boundary_returns_current_invocation_not_sealed_receipt(self):
        observed = self.observe()
        self.assertEqual(observed["invocation"], "a" * 32)
        self.assertNotIn("sealed", observed)

    def test_active_user_manager_and_normal_boot_refuse(self):
        for arguments in ({"user": "active"}, {"rescue": "inactive"}):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                self.observe(**arguments)

    def test_weakened_unit_contracts_refuse(self):
        for key, value in (("User", "0"), ("KillMode", "process"), ("Restart", "always"),
                           ("Before", ""), ("Conflicts", ""), ("InvocationID", "b" * 32)):
            snapshot = self.snapshot()
            snapshot[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.observe(snapshot=snapshot)

    def test_unknown_or_outside_process_is_not_an_exemption(self):
        for error in (PermissionError("hidden"), ValueError("outside")):
            with self.subTest(error=type(error)), self.assertRaises(type(error)):
                self.observe(exclusive=error)

    def test_real_proc_parser_checks_all_uid_fields_and_cgroup(self):
        with tempfile.TemporaryDirectory() as directory:
            process = Path(directory) / "1234"
            process.mkdir()
            (process / "status").write_text("Uid:\t1000\t0\t0\t0\n")
            (process / "cgroup").write_text("0::/outside\n")
            with patch.object(os, "getuid", return_value=1000), \
                    patch.object(Path, "iterdir", return_value=iter([process])), self.assertRaises(ValueError):
                boundary.require_exclusive_user("/system.slice/fixture.service")

    def test_proc_parser_accepts_only_maintenance_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            process = Path(directory) / "1234"
            process.mkdir()
            (process / "status").write_text("Uid:\t1000\t1000\t1000\t1000\n")
            (process / "cgroup").write_text("0::/system.slice/fixture.service/child\n")
            with patch.object(os, "getuid", return_value=1000), \
                    patch.object(Path, "iterdir", return_value=iter([process])):
                boundary.require_exclusive_user("/system.slice/fixture.service")

    def test_missing_evidence_is_not_a_disappeared_process(self):
        with tempfile.TemporaryDirectory() as directory:
            process = Path(directory) / "1234"
            process.mkdir()
            with patch.object(Path, "iterdir", return_value=iter([process])), \
                    self.assertRaisesRegex(ValueError, "process-evidence-missing"):
                boundary.require_exclusive_user("/system.slice/fixture.service")

    def test_system_observation_uses_trusted_binary_and_clean_environment(self):
        response = subprocess.CompletedProcess([], 0, stdout="ActiveState=inactive\n")
        with patch.object(boundary.shutil, "which", return_value="/trusted/systemctl"), \
                patch.object(boundary, "root_controlled") as trusted, \
                patch.object(boundary.subprocess, "run", return_value=response) as run, \
                patch.dict(os.environ, {"DBUS_SYSTEM_BUS_ADDRESS": "untrusted", "LD_PRELOAD": "untrusted"}):
            self.assertEqual(boundary.system_unit("fixture.service"), {"ActiveState": "inactive"})
        trusted.assert_called_once_with("/trusted/systemctl")
        self.assertEqual(run.call_args.kwargs["env"], {"PATH": os.defpath, "LC_ALL": "C"})

    def test_root_sticky_store_is_safe_but_writable_files_and_nonsticky_parents_are_not(self):
        def check(store_mode, tool_mode, uid=0):
            def metadata(path):
                mode = tool_mode if path.name == "tool" else store_mode if path.name == "store" else 0o40755
                return os.stat_result((mode, 0, 0, 1, uid, 0, 0, 0, 0, 0))
            with patch.object(Path, "lstat", autospec=True, side_effect=metadata):
                boundary.trusted_path("/trusted/store/tool")
        check(0o41775, 0o100755)
        for arguments in ((0o40775, 0o100755), (0o41775, 0o101775), (0o41775, 0o100755, 1000)):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                check(*arguments)


class MaintenancePlanTests(unittest.TestCase):
    def value(self):
        return {"schema": maintenance.SCHEMA, "machine": "fixture-machine",
                "created_at": time.time(), "entries": []}

    def test_plan_batch_reports_unexamined_worktrees_without_authorizing_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            listing = "\n\n".join("worktree " + str(root / name) for name in ("one", "two", "three"))
            with patch.object(maintenance, "repository", return_value={"path": str(root)}), \
                    patch.object(maintenance, "git", return_value=listing), \
                    patch.object(maintenance, "candidate", side_effect=lambda path, repo: {"path": str(path)}), \
                    patch.object(maintenance, "machine", return_value="fixture-machine"):
                value = maintenance.plan(root, limit=1, offset=1)
            self.assertEqual(value["scan"], {"total_worktrees": 3, "offset": 1, "examined": 1, "next_offset": 2})
            self.assertEqual(value["entries"], [{"path": str(root / "two"), "decision": "candidate"}])
            for limit, offset in ((0, 0), (201, 0), (1, -1)):
                with self.subTest(limit=limit, offset=offset), self.assertRaisesRegex(ValueError, "invalid-plan-range"):
                    maintenance.plan(root, limit=limit, offset=offset)

    def test_plan_requires_exact_token_host_and_freshness(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.json"
            value = self.value()
            path.write_text(json.dumps(value))
            with patch.object(maintenance, "machine", return_value="fixture-machine"):
                self.assertEqual(maintenance.load_plan(path, maintenance.digest(value)), value)
                with self.assertRaises(ValueError):
                    maintenance.load_plan(path, "0" * 64)
                value["created_at"] -= 8 * 86400
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    maintenance.load_plan(path, maintenance.digest(value))
            with patch.object(maintenance, "machine", return_value="another-machine"), self.assertRaises(ValueError):
                maintenance.load_plan(path, maintenance.digest(value))

    def test_proof_cannot_be_enabled_by_plan_environment_alone(self):
        with patch.object(boundary, "observe", side_effect=ValueError("offline boundary missing")), \
                patch.object(maintenance, "load_plan") as load, self.assertRaises(ValueError):
            maintenance.proof(Path("/candidate"), Path("/plan"), "token")
        load.assert_not_called()

    def test_apply_does_not_spawn_removal_without_boundary(self):
        with patch.object(boundary, "observe", side_effect=ValueError("offline boundary missing")), \
                patch.object(maintenance.subprocess, "run") as run, self.assertRaises(ValueError):
            maintenance.apply(Path("/plan"), "token")
        run.assert_not_called()

    def test_invalid_machine_identity_refuses(self):
        for value in (b"", b"uninitialized", b"0" * 32):
            with self.subTest(value=value), patch.object(Path, "read_bytes", return_value=value), \
                    self.assertRaisesRegex(ValueError, "invalid-machine-id"):
                maintenance.machine()

    def test_git_ignored_files_and_forensic_markers_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(path)], check=True)
            (path / ".gitignore").write_text("private-data\n")
            (path / "private-data").write_text("fixture data, not a credential")
            with self.assertRaisesRegex(ValueError, "ignored-content-requires-preservation"):
                maintenance.preservation_checks(path)
            (path / "private-data").unlink()
            maintenance.preservation_checks(path)
            (path / ".preserve-forensics").symlink_to("missing")
            with self.assertRaisesRegex(ValueError, "preserve-forensics"):
                maintenance.preservation_checks(path)

    def test_failed_maintenance_proof_never_claims_or_seals(self):
        script = '''
source "$1"
python3() { return 0; }
worktree_managed_lifetime_proof() { return 1; }
worktree_maintenance_removal_proof() { return 1; }
claim_worktree_ownership() { printf 'unexpected-claim' >&3; return 1; }
worktree_managed_prepare_removal /fixture branch 3>&1
'''
        for plan, confirmation in (("/plan", "digest"), ("/plan", ""), ("", "digest")):
            env = dict(os.environ, AIDEVOPS_WORKTREE_MAINTENANCE_PLAN=plan,
                       AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM=confirmation)
            result = subprocess.run(["bash", "-c", script, "fixture",
                                     str(SCRIPTS / "audit-worktree-removal-helper.sh")],
                                    env=env, capture_output=True, text=True, timeout=10)
            with self.subTest(plan=plan, confirmation=confirmation):
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_degraded_cwd_preserves_ordinary_statuses_and_refuses_maintenance(self):
        script = '''
source "$1"
_worktree_guard_path_is_usable() { return 0; }
is_registered_canonical() { return 1; }
_worktree_git_lock_state() { printf '%s' "$_WT_GIT_STATE_CLEAR"; return 0; }
_worktree_has_process_cwd() { return 2; }
worktree_managed_lifetime_proof() { return "$PROOF_STATUS"; }
log_worktree_removal_event() { return 0; }
if worktree_removal_guard /fixture-candidate test maintenance; then status=0; else status=$?; fi
printf '%s|%s|%s' "$status" "$WORKTREE_REMOVAL_GUARD_VISIBILITY" "$WORKTREE_REMOVAL_GUARD_REASON"
'''
        cases = (("/plan", 0, "1|degraded|maintenance-cwd-visibility-degraded"),
                 ("/plan", 1, "1|degraded|maintenance-cwd-visibility-degraded"),
                 ("", 0, "0|managed-lifetime|"),
                 ("", 1, "2|degraded|cwd-visibility-degraded"))
        for plan, status, expected in cases:
            env = dict(os.environ, AIDEVOPS_WORKTREE_MAINTENANCE_PLAN=plan,
                       AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM="fixture" if plan else "",
                       PROOF_STATUS=str(status))
            result = subprocess.run(["bash", "-c", script, "fixture",
                                     str(SCRIPTS / "audit-worktree-removal-helper.sh")],
                                    env=env, capture_output=True, text=True, timeout=10)
            with self.subTest(plan=plan, status=status):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_missing_enrollment_cannot_bypass_final_maintenance_proof(self):
        script = '''
source "$1"
python3() { return 3; }
worktree_maintenance_removal_proof() { return 1; }
worktree_managed_require_removal_proof /fixture
'''
        env = dict(os.environ, AIDEVOPS_WORKTREE_MAINTENANCE_PLAN="/plan",
                   AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM="digest")
        result = subprocess.run(["bash", "-c", script, "fixture",
                                 str(SCRIPTS / "audit-worktree-removal-helper.sh")],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_direct_proof_revalidates_repository_not_just_plan_checksum(self):
        value = {"repository": {"path": "/repository", "tip": "invented-tip"}}
        with patch.object(boundary, "observe", return_value={}), \
                patch.object(maintenance, "load_plan", return_value=value), \
                patch.object(maintenance, "repository", return_value={"tip": "current-tip"}) as lookup, \
                patch.object(maintenance, "candidate") as candidate, \
                self.assertRaisesRegex(ValueError, "repository-changed"):
            maintenance.proof(Path("/candidate"), Path("/plan"), "checksum")
        lookup.assert_called_once_with(Path("/repository"))
        candidate.assert_not_called()


class MaintenancePolicyTests(unittest.TestCase):
    def policy(self, scenario, branch="feature/example"):
        # Reuse the shell-gh stub pattern in the Pulse retention regressions;
        # exercise the actual shared predicates, without GitHub writes or reads.
        script = '''
gh() {
    local operation="$1 $2"
    case "$operation" in
    "pr list")
        case "$SCENARIO" in
        unavailable) return 1 ;;
        malformed) printf '[{}]' ;;
        truncated) jq -nc '[range(1;101) | {number:.,state:"MERGED"}]' ;;
        open) printf '[{"number":12,"state":"OPEN"}]' ;;
        *) printf '[{"number":12,"state":"MERGED"}]' ;;
        esac ;;
    "issue view") [[ "$SCENARIO" != issue-protected ]] || printf 'preserve-forensics\n' ;;
    "pr view")
        if [[ "$*" == *"--json state"* ]]; then
            printf 'OPEN\n'
        elif [[ "$SCENARIO" == pr-protected ]]; then
            printf 'security\n'
        fi ;;
    "api repos/fixture/repo/issues/42/comments") printf '[]' ;;
    *) return 1 ;;
    esac
    return 0
}
export -f gh
bash "$1" "$2" "$3" fixture/repo
'''
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run(["bash", "-c", script, "fixture",
                                   str(SCRIPTS / "worktree-maintenance-policy.sh"), directory, branch],
                                  env=dict(os.environ, SCENARIO=scenario),
                                  capture_output=True, text=True, timeout=10)

    def test_terminal_unprotected_pr_allows_policy(self):
        result = self.policy("clear")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_open_protected_unknown_or_truncated_prs_refuse(self):
        for scenario in ("open", "pr-protected", "unavailable", "malformed", "truncated"):
            with self.subTest(scenario=scenario):
                result = self.policy(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_enrichment_issue_retention_and_repair_pr_are_checked(self):
        result = self.policy("issue-protected", "feature/enrichment-42-fixture")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("protected-preserve-forensics", result.stdout)
        result = self.policy("clear", "repair/pr-42-fixture")
        self.assertEqual(result.returncode, 1, result.stderr)


class MaintenancePreservationTests(unittest.TestCase):
    def exercise_removal(self, authorized):
        # Reuse the archive suite's isolated real Git fixture. Only external
        # authorization/process visibility is substituted here; capture, restore,
        # source matching, native removal and registry contents remain real.
        spec = importlib.util.spec_from_file_location("archive_fixture", Path(__file__).with_name(
            "test-worktree-archive-lifecycle.py"))
        fixture_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture_module)
        fixture = fixture_module.ArchiveLifecycle()
        self.addCleanup(fixture.doCleanups)
        fixture.setUp()
        fixture.env.update(AIDEVOPS_WORKTREE_TRASH_ROOT=str(fixture.archives),
                           AIDEVOPS_CLEANUP_LOG=str(fixture.root / "cleanup.log"),
                           AIDEVOPS_WORKTREE_MAINTENANCE_PLAN=str(fixture.root / "plan"),
                           AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM="fixture-confirmation",
                           AIDEVOPS_WORKTREE_MANAGER="legacy-guards",
                           FIXTURE_AUTHORIZED="0" if authorized else "1",
                           FIXTURE_PROOF_LOG=str(fixture.root / "proof.log"))
        if os.environ.get("AIDEVOPS_TEST_GIT_BIN"):
            fixture.env["AIDEVOPS_REAL_GIT_BIN"] = os.environ["AIDEVOPS_TEST_GIT_BIN"]
        fixture.run_command("bash", "-c", 'source "$1" && _init_registry_db',
                            "registry", SCRIPTS / "shared-worktree-registry.sh")
        record = {"manager": maintenance.owner.MANAGER, "state": "running",
                  "identity": maintenance.owner.identity(fixture.work),
                  "launches": [{"kind": maintenance.owner.KIND, "evidence": "observed"}]}
        original = json.dumps(record)
        with closing(maintenance.sqlite3.connect(fixture.env["WORKTREE_REGISTRY_DB"])) as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS worktree_managed_lifetimes (path TEXT PRIMARY KEY, record TEXT)")
            db.execute("INSERT INTO worktree_managed_lifetimes VALUES (?, ?)", (str(fixture.work), original))
        with patch.dict(os.environ, fixture.env):
            self.assertEqual(maintenance.legacy(fixture.work), record)
            maintenance.preservation_checks(fixture.work)
        expected = (fixture.work / "mixed.txt").read_bytes()
        script = '''
set -euo pipefail
source "$1/audit-worktree-removal-helper.sh"
_worktree_has_process_cwd() { return 1; }
worktree_maintenance_removal_proof() {
    printf 'checked\n' >> "$FIXTURE_PROOF_LOG"
    return "$FIXTURE_AUTHORIZED"
}
archive_worktree_path_recoverably "$2" test-maintenance integration
printf 'ARCHIVE=%s\n' "$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
remove_archived_worktree_path "$2" "$WORKTREE_RECOVERABLE_ARCHIVE_PATH" \
    test-maintenance maintenance-test '' false false
'''
        result = fixture.run_command("bash", "-c", script, "fixture", SCRIPTS, fixture.work,
                                     cwd=fixture.repo, check=False)
        self.assertEqual(result.returncode, 0 if authorized else 1,
                         (result.stdout + result.stderr).decode(errors="replace"))
        self.assertEqual((fixture.root / "proof.log").read_text(), "checked\n")
        self.assertEqual(fixture.work.exists(), not authorized)
        with closing(maintenance.sqlite3.connect(fixture.env["WORKTREE_REGISTRY_DB"])) as db:
            self.assertEqual(db.execute("SELECT record FROM worktree_managed_lifetimes WHERE path = ?",
                                        (str(fixture.work),)).fetchone()[0], original)
        locations = [line.removeprefix("ARCHIVE=") for line in result.stdout.decode().splitlines()
                     if line.startswith("ARCHIVE=")]
        self.assertEqual(len(locations), 1)
        archive = Path(locations[0])
        self.assertTrue((archive / "manifest.json").is_file())
        journal = json.loads(next(fixture.archives.glob(".producer-transactions/*/journal.json")).read_text())
        self.assertEqual(journal["source_removal_outcome"], "removed" if authorized else "pending")
        if authorized:
            self.assertEqual(journal["canonical_restore"]["state"], "cleaned")
            restored = fixture.root / "independent-restore"
            fixture.helper("restore", archive, "--target", restored)
            self.assertEqual((restored / "mixed.txt").read_bytes(), expected)
            self.assertNotIn(str(fixture.work).encode(), fixture.git(fixture.repo, "worktree", "list", "--porcelain"))

    def test_authorized_native_removal_restores_and_keeps_legacy_record(self):
        self.exercise_removal(True)

    def test_lost_authorization_retains_source_archive_and_legacy_record(self):
        self.exercise_removal(False)


if __name__ == "__main__":
    unittest.main()
