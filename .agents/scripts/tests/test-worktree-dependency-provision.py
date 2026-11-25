#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fixture-only dependency provisioning and ownership regression tests."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed offline fixture programs only.
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
GIT = shutil.which("git")
BASH = shutil.which("bash")
if not GIT or not BASH:
    raise RuntimeError("Git and Bash are required for fixture verification")
SPEC = importlib.util.spec_from_file_location("provision", SCRIPTS / "worktree-dependency-provision.py")
provision = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provision)


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        previous_umask = os.umask(0o022)
        self.addCleanup(os.umask, previous_umask)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.wt = self.root / "worktree"
        self.repo.mkdir()
        self.git(self.repo, "init", "-q")
        self.package = {"name": "fixture", "version": "1.0.0", "dependencies": {"example": "1.0.0"}}
        self.metadata = {"version": "1.0.0", "resolved": "fixture:example"}
        self.lock = {"lockfileVersion": 3, "packages": {"": self.package, "node_modules/example": self.metadata}}
        self.write(self.repo / "package.json", self.package)
        self.write(self.repo / "package-lock.json", self.lock)
        (self.repo / ".gitignore").write_text("node_modules/\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        self.git(self.repo, "worktree", "add", "-qb", "fixture-work", str(self.wt))
        self.modules = self.repo / "node_modules"
        self.write(self.modules / "example" / "package.json", {"name": "example", "version": "1.0.0"})
        (self.modules / "example" / "index.js").write_text("export const fixture = 1;\n")
        self.write(self.modules / ".package-lock.json", {"packages": {"node_modules/example": self.metadata}})

    @staticmethod
    def git(path, *args):
        return subprocess.check_output(  # nosec B603 -- resolved Git and fixture-owned argv, no shell.
            [GIT, "-C", str(path), *args], stderr=subprocess.DEVNULL, text=True).strip()

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def validate(self):
        return provision.identity(self.repo, self.wt, Path("."))

    def run_restore(self, owner="current", exact="true", root="auto", budget="67108864", interactive=False):
        # All ownership and controller inputs are fixtures; never use the live registry.
        script = r'''
source "$1/worktree-helper-add.sh"
source "$1/pulse-dispatch-worker-launch.sh"
check_worktree_owner_snapshot() {
    if [[ "$OWNER" == current ]]; then printf '%s|fixture-session||31372|fixture-created|fixture-start\n' "$$";
    else printf '999999|foreign-session||31372|fixture-created|fixture-start\n'; fi
}
worktree_has_exact_owner_contract() { [[ "$EXACT" == true ]]; }
_dlw_node_modules_restore_acquire_lock() { return 0; }
_dlw_node_modules_restore_release_lock() { return 0; }
_restore_worktree_node_modules_acquire_lock() { return 0; }
_restore_worktree_node_modules_release_lock() { return 0; }
if [[ "$RESTORE_MODE" == interactive ]]; then
    _restore_worktree_node_modules "$2" "$3" >>"$LOGFILE" 2>&1
else
    _dlw_restore_worktree_deps "$2" "$3"
fi
'''
        env = {**os.environ, "OWNER": owner, "EXACT": exact,
               "RESTORE_MODE": "interactive" if interactive else "headless",
               "LOGFILE": str(self.root / "restore.log"), "AIDEVOPS_WORKSPACE_DIR": str(self.root),
               "WORKTREE_NODE_MODULES_RESTORE_ROOT_ENABLED": root,
               "WORKTREE_NODE_MODULES_RESTORE_ENABLED": "1",
               "WORKTREE_NODE_MODULES_RESTORE_MAX_BYTES": budget}
        # Fixed shell program above; all parameters are isolated fixture paths.
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        subprocess.run(  # nosec B603 -- resolved Bash, fixed fixture program and fixture-only argv.
            [BASH, "-c", script, "fixture", str(SCRIPTS), str(self.wt), str(self.repo)],
                       env=env, check=True, capture_output=True, text=True, timeout=20)

    def test_bounded_read_and_repeat_preserve_checkpoint(self):
        self.assertEqual(self.validate()[0], self.modules)
        head = self.git(self.wt, "rev-parse", "HEAD")
        (self.wt / "checkpoint.txt").write_text("PR fixture #42; pending request perm-fixture")
        self.run_restore()
        copied = self.wt / "node_modules" / "example" / "index.js"
        self.assertEqual(copied.read_text(), "export const fixture = 1;\n")
        before = copied.stat().st_mtime_ns
        self.run_restore()
        self.assertEqual(copied.stat().st_mtime_ns, before)
        self.assertEqual(self.git(self.wt, "rev-parse", "HEAD"), head)
        self.assertIn("perm-fixture", (self.wt / "checkpoint.txt").read_text())
        self.assertFalse(list(self.wt.glob(".aidevops-deps-*")))

    def test_root_disabled(self):
        self.run_restore(root="0")
        self.assertFalse((self.wt / "node_modules").exists())

    def test_foreign_live_or_dead_owner(self):
        self.run_restore(owner="foreign")
        self.assertFalse((self.wt / "node_modules").exists())

    def test_recycled_owner_generation(self):
        self.run_restore(exact="false")
        self.assertFalse((self.wt / "node_modules").exists())

    def test_byte_budget(self):
        self.run_restore(budget="10")
        self.assertFalse((self.wt / "node_modules").exists())

    def test_copy_enforces_budget_without_preflight(self):
        stage = self.wt / "stage"
        stage.mkdir(mode=0o700)
        with self.assertRaises(provision.Rejected):
            provision.snapshot(self.modules, 10, 20000, stage)
        self.assertLessEqual(sum(p.stat().st_size for p in stage.rglob("*") if p.is_file()), 10)

    def test_stale_pnpm_staging_directory_is_skipped(self):
        self.make_pnpm()
        (self.modules / "example_tmp_123").mkdir()
        self.run_restore()
        self.assertTrue((self.wt / "node_modules" / "example" / "index.js").exists())
        self.assertFalse((self.wt / "node_modules" / "example_tmp_123").exists())

    def test_root_markers_and_tool_caches_are_skipped(self):
        skipped = (".metadata_never_index", ".DS_Store", ".vite", ".vite-temp", ".cache")
        for manager in ("npm", "pnpm"):
            if manager == "pnpm":
                self.make_pnpm()
            with self.subTest(manager=manager):
                for name in skipped[:2]:
                    (self.modules / name).write_bytes(b"")
                for name in skipped[2:]:
                    (self.modules / name / "deps").mkdir(parents=True, exist_ok=True)
                    (self.modules / name / "deps" / "chunk.js").write_text("fixture only")
                self.run_restore()
                self.assertTrue((self.wt / "node_modules" / "example" / "index.js").exists())
                for name in skipped:
                    self.assertFalse(os.path.lexists(self.wt / "node_modules" / name))
                shutil.rmtree(self.wt / "node_modules")
        # Allowlisted names with another type are still unrecorded package roots.
        shutil.rmtree(self.modules / ".cache")
        (self.modules / ".cache").symlink_to(".pnpm")
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())
        (self.modules / ".cache").unlink()
        (self.modules / ".metadata_never_index").unlink()
        (self.modules / ".metadata_never_index").mkdir()
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_dangling_bin_link_is_copied_as_is(self):
        bin_dir = self.modules / "example" / "node_modules" / ".bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "parser").symlink_to("../@babel/parser/bin/babel-parser.js")
        stage = self.wt / "stage"
        stage.mkdir(mode=0o700)
        provision.snapshot(self.modules, 67108864, 20000, stage)
        self.assertTrue((stage / "example" / "node_modules" / ".bin" / "parser").is_symlink())

    def test_dangling_bin_link_escaping_root_is_rejected(self):
        bin_dir = self.modules / ".bin"
        bin_dir.mkdir()
        (bin_dir / "parser").symlink_to("../../outside")
        with self.assertRaises(provision.Rejected):
            provision.snapshot(self.modules, 67108864, 20000)

    def test_dangling_link_outside_bin_reports_specific_reason(self):
        (self.modules / "example" / "gone").symlink_to("missing-target")
        with self.assertRaises(provision.Rejected) as caught:
            provision.snapshot(self.modules, 67108864, 20000)
        self.assertEqual(str(caught.exception), "dangling-dependency-link")

    def test_source_far_over_budget_is_refused_without_walk(self):
        (self.modules / "example" / "big.bin").write_bytes(b"x" * 8192)
        result = subprocess.run(  # nosec B603 -- resolved Bash, fixed fixture program and fixture-only argv.
            [BASH, "-c", 'source "$1/worktree-helper-add.sh"; _provision_source_clearly_over_budget "$2" 1024',
             "fixture", str(SCRIPTS), str(self.modules)], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0)

    def test_entry_budget(self):
        with self.assertRaises(provision.Rejected):
            provision.snapshot(self.modules, 67108864, 1)

    def test_stale_package(self):
        self.write(self.wt / "package.json", {"name": "different"})
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_missing_package_identity(self):
        for parent in (self.repo, self.wt):
            self.write(parent / "package.json", {})
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_stale_lock(self):
        self.write(self.wt / "package-lock.json", {})
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_stale_installed_package(self):
        self.write(self.modules / "example" / "package.json", {"name": "example", "version": "2.0.0"})
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_missing_dependencies(self):
        shutil.rmtree(self.modules)
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_missing_installed_lock(self):
        (self.modules / ".package-lock.json").unlink()
        with self.assertRaises(OSError):
            self.validate()

    def test_symlinked_manifest(self):
        (self.repo / "package.json").unlink()
        (self.repo / "package.json").symlink_to(self.wt / "package.json")
        with self.assertRaises(OSError):
            self.validate()

    def test_escaping_link_and_credentials(self):
        (self.modules / "escape").symlink_to(self.repo)
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())
        (self.modules / "escape").unlink()
        (self.modules / ".npmrc").write_text("fixture only")
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_destination_symlink(self):
        (self.wt / "node_modules").symlink_to(self.modules)
        self.run_restore()
        self.assertTrue((self.wt / "node_modules").is_symlink())

    def test_source_not_shared_writable(self):
        (self.modules / "example" / "index.js").chmod(0o666)
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_special_file(self):
        os.mkfifo(self.modules / "fifo")
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def make_pnpm(self):
        lock_text = "lockfileVersion: '9.0'\npackages:\n  example@1.0.0:\n    resolution: {integrity: fixture}\n"
        for parent in (self.repo, self.wt):
            (parent / "package-lock.json").unlink()
            (parent / "pnpm-lock.yaml").write_text(lock_text)
        (self.modules / ".package-lock.json").unlink()
        store = self.modules / ".pnpm" / "example@1.0.0" / "node_modules"
        store.mkdir(parents=True)
        (self.modules / "example").rename(store / "example")
        (self.modules / "example").symlink_to(".pnpm/example@1.0.0/node_modules/example")
        (self.modules / ".pnpm" / "lock.yaml").write_text(lock_text)

    def test_pnpm_contained_links(self):
        self.make_pnpm()
        self.run_restore()
        copied = self.wt / "node_modules" / "example" / "index.js"
        self.assertTrue(copied.resolve().is_relative_to(self.wt))
        self.assertEqual(copied.read_text(), "export const fixture = 1;\n")

    def make_workspace(self):
        self.make_pnpm()
        for parent in (self.repo, self.wt):
            (parent / "pnpm-workspace.yaml").write_text("packages:\n  - 'packages/*'\n  - 'apps/*'\n")
            for relative in ("packages/one", "packages/two", "apps/web"):
                self.write(parent / relative / "package.json", {
                    "name": relative.split("/")[-1], "version": "1.0.0", "dependencies": {"example": "1.0.0"}})
        for relative in ("packages/one", "packages/two", "apps/web"):
            modules = self.repo / relative / "node_modules"
            modules.mkdir()
            (modules / "example").symlink_to("../../../node_modules/example")
            (modules / "one").symlink_to("../../../packages/one")
        (self.modules / "one").symlink_to("../packages/one")

    def test_workspace_restores_all_members_and_isolates_writes(self):
        self.make_workspace()
        self.run_restore()
        for relative in ("packages/one", "packages/two", "apps/web"):
            copied = self.wt / relative / "node_modules/example/index.js"
            self.assertEqual(copied.read_text(), "export const fixture = 1;\n")
            self.assertTrue(copied.resolve().is_relative_to(self.wt))
            self.assertEqual((self.wt / relative / "node_modules/one").resolve(), self.wt / "packages/one")
        copied.write_text("changed only in worktree")
        self.assertEqual((self.modules / "example/index.js").read_text(), "export const fixture = 1;\n")
        log = (self.root / "restore.log").read_text()
        self.assertEqual(log.count("outcome=provisioned elapsed_seconds="), 4)

    def test_workspace_lock_mismatch_and_escape(self):
        self.make_workspace()
        (self.wt / "pnpm-lock.yaml").write_text("different")
        self.run_restore()
        self.assertIn("stale-lock-identity", (self.root / "restore.log").read_text())
        self.assertFalse((self.wt / "node_modules").exists())
        (self.wt / "pnpm-lock.yaml").write_bytes((self.repo / "pnpm-lock.yaml").read_bytes())
        (self.modules / "example/escape").symlink_to(self.root)
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    @staticmethod
    def fallback_clone(_source, output, name):
        """Platform-independent stand-in for an unsupported clone boundary."""
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        return os.open(name, flags, 0o600, dir_fd=output), False

    def test_workspace_unsupported_clone_keeps_byte_budget(self):
        from unittest.mock import patch
        self.make_workspace()
        modules, inventory = self.validate()
        stage = self.wt / "stage"
        stage.mkdir(mode=0o700)
        with patch("_worktree_dependency_payload.clone_descriptor", side_effect=self.fallback_clone):
            with self.assertRaisesRegex(provision.Rejected, "byte-budget-exceeded"):
                provision.snapshot(modules, 10, 20000, stage, inventory)

    def test_workspace_original_target_cannot_escape_through_worktree_alias(self):
        self.make_workspace()
        (self.repo / "alias").symlink_to("packages", target_is_directory=True)
        (self.wt / "alias").symlink_to(self.root, target_is_directory=True)
        (self.modules / "example/escape").symlink_to("../../../../../alias/one")
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_workspace_missing_member_dependency_is_rejected(self):
        self.make_workspace()
        (self.repo / "packages/one/node_modules/example").unlink()
        modules, inventory = provision.identity(self.repo, self.wt, Path("packages/one"))
        with self.assertRaisesRegex(provision.Rejected, "incomplete-package-inventory"):
            provision.snapshot(modules, 67108864, 20000, inventory=inventory)

    def test_hoisted_node_linker_is_refused_before_member_walk(self):
        # t19381: hoisted layouts can never satisfy member checks; name the reason.
        self.make_workspace()
        for parent in (self.repo, self.wt):
            config = parent / "pnpm-workspace.yaml"
            config.write_text(config.read_text() + "nodeLinker: hoisted  # flat tree\n")
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        result = subprocess.run(  # nosec B603 -- current interpreter, fixed helper and fixture-owned arguments.
            [sys.executable, str(SCRIPTS / "worktree-dependency-provision.py"),
             str(self.repo), str(self.wt), ".", "--workspace-list"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "dependency-provision-rejected reason=unsupported-node-linker-hoisted\n")
        self.run_restore(interactive=True)
        log = (self.root / "restore.log").read_text()
        self.assertNotIn("outcome=provisioned", log)
        self.assertNotIn("incomplete-package-inventory", log)
        self.assertFalse((self.wt / "node_modules").exists())

    def test_hoisted_npmrc_is_refused_for_single_package_pnpm(self):
        self.make_pnpm()
        (self.repo / ".npmrc").write_text("auto-install-peers=true\nnode-linker = hoisted\n")
        with self.assertRaisesRegex(provision.Rejected, "unsupported-node-linker-hoisted"):
            self.validate()
        (self.repo / ".npmrc").write_text("node-linker=isolated\n")
        self.validate()

    def test_workspace_interactive_hidden_members_and_exclusions(self):
        self.make_workspace()
        for parent in (self.repo, self.wt):
            (parent / "packages/one").rename(parent / "packages/.one")
            (parent / "pnpm-workspace.yaml").write_text("packages:\n  - packages/*\n  - '!packages/two'\n  - apps/*\n")
        for path in (self.modules / "one", self.repo / "packages/.one/node_modules/one",
                     self.repo / "packages/two/node_modules/one", self.repo / "apps/web/node_modules/one"):
            path.unlink()
        self.run_restore(interactive=True)
        self.assertTrue((self.wt / "packages/.one/node_modules/example/package.json").is_file())
        self.assertTrue((self.wt / "apps/web/node_modules/example/package.json").is_file())
        self.assertFalse((self.wt / "packages/two/node_modules").exists())

    def test_workspace_fallback_copies_multiple_chunks(self):
        from unittest.mock import patch
        self.make_workspace()
        payload = self.modules / "example/payload"
        payload.write_bytes(b"fixture" * 200000)
        modules, inventory = self.validate()
        stage = self.wt / "stage"
        stage.mkdir(mode=0o700)
        with patch("_worktree_dependency_payload.clone_descriptor", side_effect=self.fallback_clone):
            provision.snapshot(modules, 67108864, 20000, stage, inventory)
        copied = stage / ".pnpm/example@1.0.0/node_modules/example/payload"
        self.assertEqual(copied.read_bytes(), payload.read_bytes())

    def test_workspace_clone_exceeds_copy_budget_without_shared_writes(self):
        from _worktree_dependency_payload import clone_descriptor
        from _worktree_dependency_identity import open_directory
        self.make_workspace()
        stage = self.wt / "stage"
        stage.mkdir(mode=0o700)
        payload = self.modules / "example/payload"
        payload.write_bytes(b"fixture" * 200000)
        # Probe the real filesystem, not a mocked successful ioctl.
        with payload.open("rb") as source, open_directory(stage) as output:
            target, cloned = clone_descriptor(source.fileno(), output, "probe")
            os.close(target)
        (stage / "probe").unlink()
        if not cloned:
            self.skipTest("filesystem lacks CoW; bounded fallback is tested separately")
        modules, inventory = self.validate()
        provision.snapshot(modules, 10, 1, stage, inventory)
        copied = stage / ".pnpm/example@1.0.0/node_modules/example/payload"
        self.assertEqual(copied.read_bytes(), payload.read_bytes())
        copied.write_text("isolated")
        self.assertGreater(payload.stat().st_size, 1000000)

    def test_workspace_member_command_runs_without_install(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("Node is unavailable")
        self.make_workspace()
        self.run_restore()
        result = subprocess.check_output(  # nosec B603 -- resolved Node, fixed offline fixture expression.
            [node, "-p", "require('example/package.json').version"],
            cwd=self.wt / "packages/one", text=True, timeout=10)
        self.assertEqual(result.strip(), "1.0.0")

    def test_extra_unrecorded_package(self):
        self.write(self.modules / "extra" / "package.json", {"name": "extra", "version": "1.0.0"})
        self.run_restore()
        self.assertFalse((self.wt / "node_modules").exists())

    def test_manifestless_package_roots_and_files(self):
        for manager in ("npm", "pnpm"):
            if manager == "pnpm":
                self.make_pnpm()
            for extra in ("extra/index.js", "extra.js", "@extra.js", ".extra.js"):
                with self.subTest(manager=manager, extra=extra):
                    payload = self.modules / extra
                    payload.parent.mkdir(parents=True, exist_ok=True)
                    payload.write_text("fixture only")
                    self.run_restore()
                    self.assertFalse((self.wt / "node_modules").exists())
                    payload.unlink()
                    if payload.parent != self.modules:
                        payload.parent.rmdir()

    def test_missing_expected_installed_package(self):
        self.lock["packages"]["node_modules/missing"] = {"version": "1.0.0"}
        for parent in (self.repo, self.wt):
            self.write(parent / "package-lock.json", self.lock)
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_shared_worktree_root_rejected(self):
        self.wt.chmod(0o777)
        with self.assertRaises(provision.Rejected):
            self.validate()

    def test_malformed_lock_is_redacted(self):
        for parent in (self.repo, self.wt):
            self.write(parent / "package-lock.json", [])
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        result = subprocess.run(  # nosec B603 -- current interpreter, fixed helper and fixture-owned arguments.
            [sys.executable, str(SCRIPTS / "worktree-dependency-provision.py"),
                                 str(self.repo), str(self.wt), "."], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "dependency-provision-rejected reason=invalid-object-metadata\n")

    def test_unexpected_os_error_reports_errno_without_path(self):
        (self.wt / "package-lock.json").unlink()
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        result = subprocess.run(  # nosec B603 -- current interpreter, fixed helper and fixture-owned arguments.
            [sys.executable, str(SCRIPTS / "worktree-dependency-provision.py"),
                                 str(self.repo), str(self.wt), "."], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "dependency-provision-rejected reason=os-error-ENOENT\n")

    def test_atomic_promotion_does_not_replace_existing_directory(self):
        stage = self.wt / ".aidevops-deps-fixture" / "node_modules"
        stage.mkdir(parents=True, mode=0o700)
        stage.parent.chmod(0o700)
        destination = self.wt / "node_modules"
        destination.mkdir()
        with self.assertRaises(provision.Rejected):
            provision.publish(stage, self.wt, Path("."))
        self.assertTrue(stage.is_dir())
        self.assertTrue(destination.is_dir())


if __name__ == "__main__":
    unittest.main()
