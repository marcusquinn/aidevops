#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Git/tar metadata cases using the existing archive lifecycle fixture."""

import hashlib
import json
import os
import stat
import tarfile

from worktree_archive_snapshot import git_snapshot


class MetadataCases:
    def test_untracked_tar_preserves_private_modes_and_internal_links(self):
        target = self.work / "untracked.txt"
        target.write_text("unique local content\n")
        target.chmod(0o600)
        os.link(target, self.work / "hard-link")
        os.link(target, self.root / "outside-link")
        archive = self.archive()
        restored = self.root / "restored-links"
        self.helper("verify", archive)
        self.helper("restore", archive, "--target", restored)
        self.assertEqual((restored / "untracked.txt").stat().st_ino, (restored / "hard-link").stat().st_ino)
        self.assertEqual(stat.S_IMODE((restored / "untracked.txt").stat().st_mode), 0o600)
        self.assertEqual((restored / "untracked.txt").read_bytes(), target.read_bytes())
        self.assertEqual((restored / "untracked.txt").stat().st_nlink, 2)
        self.assertEqual(git_snapshot(self.work), git_snapshot(restored))

    def test_tracked_modes_use_git_without_metadata_artifact(self):
        source = self.work / "mixed.txt"
        source.chmod(0o600)
        archive = self.archive()
        manifest = json.loads((archive / "manifest.json").read_text())
        self.assertNotIn("tracked_modes_sha256", manifest["source_fingerprint"])
        self.assertFalse((archive / "file-modes-v1.json").exists())
        self.helper("verify", archive)
        restored = self.root / "restored-private-mode"
        self.helper("restore", archive, "--target", restored)
        self.assertEqual(stat.S_IMODE((restored / "mixed.txt").stat().st_mode), 0o644)
        self.assertEqual((restored / "mixed.txt").read_bytes(), source.read_bytes())
        self.assertEqual(git_snapshot(self.work), git_snapshot(restored))
        self.assertTrue(source.exists())

    def test_tar_rejects_hard_links_outside_prior_regular_payload(self):
        (self.work / "new.txt").write_bytes(b"must survive\n")
        archive = self.archive()
        payload = archive / "untracked.tar.gz"
        manifest_path = archive / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        for linkname in ("../outside", "/outside", "mixed.txt", "alias", "link"):
            with self.subTest(linkname=linkname):
                with tarfile.open(payload, "w:gz") as output:
                    alias = tarfile.TarInfo("alias")
                    alias.type, alias.linkname = tarfile.SYMTYPE, "mixed.txt"
                    output.addfile(alias)
                    link = tarfile.TarInfo("link")
                    link.type, link.linkname = tarfile.LNKTYPE, linkname
                    output.addfile(link)
                for entry in manifest["artifacts"]:
                    if entry["name"] == payload.name:
                        entry.update(size=payload.stat().st_size,
                                     sha256=hashlib.sha256(payload.read_bytes()).hexdigest())
                manifest_path.write_text(json.dumps(manifest))
                target = self.root / "unsafe-restore"
                result = self.helper("restore", archive, "--target", target, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"hard link must reference an earlier regular payload member", result.stderr)
                self.assertFalse(target.exists())
