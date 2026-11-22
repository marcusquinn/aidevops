#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Archive retention race and failed-restoration cases for the lifecycle runner."""

from contextlib import redirect_stderr
import importlib.util
import io
import os
from pathlib import Path
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "worktree-archive-helper.sh"


class PruneCases:
    @staticmethod
    def prune_module():
        spec = importlib.util.spec_from_file_location("archive_prune", HELPER.with_name("worktree_archive_prune.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_pin_added_during_verification_preserves_claimed_archive(self):
        archive = self.archive()
        module = self.prune_module()
        entry = module.inspect(self.archives, archive)
        original_verify = module.verify

        def pin_during_verify(helper, directory):
            original_verify(helper, directory)
            (directory / module.PIN).touch()

        with patch.object(module, "verify", pin_during_verify):
            with self.assertRaises(ValueError):
                module.remove_verified(self.archives, module.identity(self.archives), entry, HELPER)
        retained = list(self.archives.glob(".prune-*/archive"))
        self.assertEqual(len(retained), 1)
        self.assertTrue((retained[0] / module.PIN).exists())
        self.helper("verify", retained[0])

    def test_replacement_at_original_name_is_never_deleted(self):
        archive = self.archive()
        module = self.prune_module()
        entry = module.inspect(self.archives, archive)
        original_rename = os.rename

        def replace_after_claim(*args, **kwargs):
            original_rename(*args, **kwargs)
            archive.mkdir()
            (archive / "replacement-data").write_text("keep me")

        with patch.object(module.os, "rename", replace_after_claim):
            module.remove_verified(self.archives, module.identity(self.archives), entry, HELPER)
        self.assertEqual((archive / "replacement-data").read_text(), "keep me")

    def test_failed_prune_restore_reports_retained_transaction(self):
        module = self.prune_module()
        for reason in ("occupied", "unavailable"):
            with self.subTest(reason=reason):
                archive = self.archive()
                entry = module.inspect(self.archives, archive)
                target = module.Target(self.archives, module.identity(self.archives), HELPER, "apply")
                replacement_identity = []

                def reject_archive(helper, directory):
                    if reason == "occupied":
                        archive.mkdir()
                        replacement_identity.append(module.identity(archive))
                    raise ValueError("unverifiable archive")

                stderr = io.StringIO()
                with patch.object(module, "verify", reject_archive), redirect_stderr(stderr):
                    if reason == "unavailable":
                        with patch.object(module.ctypes, "CDLL", return_value=object()):
                            result = module.attempt(target, entry)
                    else:
                        result = module.attempt(target, entry)
                self.assertIs(result, False)
                retained = [path for path in self.archives.glob(".prune-*/archive")
                            if (path / "manifest.json").read_bytes() == entry[4]]
                self.assertTrue(retained)
                self.assertIn(f"retained-transaction\t{retained[-1].parent}", stderr.getvalue())
                if reason == "occupied":
                    self.assertEqual(module.identity(archive), replacement_identity[0])
                    self.assertEqual(list(archive.iterdir()), [])
                else:
                    self.assertFalse(archive.exists())
