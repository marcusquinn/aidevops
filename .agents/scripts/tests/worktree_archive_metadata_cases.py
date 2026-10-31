#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Git/tar metadata cases using the existing archive lifecycle fixture."""

import ctypes
import errno
import hashlib
import json
import os
import stat
import tarfile
from unittest.mock import Mock, patch

import worktree_archive_filesystem as filesystem
import worktree_archive_xattrs as xattrs
from worktree_archive_snapshot import git_snapshot
from worktree_recovery_retirement_transaction import inventory


class MetadataCases:
    def test_symlink_permission_bits_do_not_block_capture(self):
        # GH#36279: macOS `ln -s` gives 0o755 links; only the target is evidence.
        observed = Mock(st_uid=os.geteuid(), st_gid=os.getegid(), st_nlink=1)
        for tar_metadata in (False, True):
            for mode in (0o777, 0o755, 0o700):
                observed.st_mode = stat.S_IFLNK | mode
                filesystem.supported_metadata(observed, [], tar_metadata)
            for mode in (0o1755, 0o2755, 0o4777):
                observed.st_mode = stat.S_IFLNK | mode
                with self.assertRaises(ValueError):
                    filesystem.supported_metadata(observed, [], tar_metadata)
        observed.st_mode = stat.S_IFLNK | 0o755
        observed.st_nlink = 2
        with self.assertRaises(ValueError):
            filesystem.supported_metadata(observed, [])
        observed.st_nlink = 1
        with self.assertRaises(ValueError):
            filesystem.supported_metadata(observed, ["user.must-preserve"])
        observed.st_uid += 1
        with self.assertRaises(ValueError):
            filesystem.supported_metadata(observed, [])
        link = self.work / "umask-link"
        link.symlink_to("/nonexistent")
        self.assertEqual(filesystem.fingerprint(self.work, b"umask-link", True), ["symlink", "/nonexistent"])

    def test_darwin_missing_os_xattr_uses_nofollow_and_descriptor_abi(self):
        payload = b"com.apple.provenance\0com.apple.quarantine\0"

        def read_attributes(target, buffer, size, options):
            if buffer is not None:
                ctypes.memmove(buffer, payload, len(payload))
            return len(payload)

        libc = Mock()
        libc.listxattr.side_effect = read_attributes
        libc.flistxattr.side_effect = read_attributes
        with patch.object(xattrs.sys, "platform", "darwin"), patch.object(
                xattrs.ctypes, "CDLL", return_value=libc), patch.dict(os.__dict__):
            os.__dict__.pop("listxattr", None)
            link = self.work / "link"
            link.symlink_to("mixed.txt")
            self.assertEqual(xattrs.list_xattrs(link), ["com.apple.quarantine"])
            self.assertEqual(libc.listxattr.call_args.args[0], os.fsencode(link))
            self.assertEqual(libc.listxattr.call_args.args[3], 1)
            with (self.work / "mixed.txt").open("rb") as source:
                self.assertEqual(xattrs.list_xattrs(source.fileno()), ["com.apple.quarantine"])
                self.assertEqual(libc.flistxattr.call_args.args[0], source.fileno())
                self.assertEqual(libc.flistxattr.call_args.args[3], 0)

    def test_retirement_metadata_policy_and_inspection_failure(self):
        with patch.object(xattrs.sys, "platform", "darwin"), patch.object(
                xattrs, "darwin_xattrs", return_value=["com.apple.provenance"]), patch.dict(os.__dict__):
            os.__dict__.pop("listxattr", None)
            self.assertTrue(inventory(self.work))
            filesystem.supported_directories(self.work)
        with patch.object(xattrs.os, "listxattr", side_effect=OSError("unavailable"), create=True):
            with self.assertRaisesRegex(ValueError, "retirement:metadata-inspection-unavailable"):
                inventory(self.work)
        with patch.object(xattrs.os, "listxattr", return_value=["user.must-preserve"], create=True):
            with self.assertRaisesRegex(ValueError, "retirement:unsupported-metadata"):
                inventory(self.work)

    def test_darwin_xattr_size_races_fail_closed(self):
        libc = Mock()
        libc.listxattr.side_effect = [8, -1, 8, -1, 8, -1]
        with patch.object(xattrs.ctypes, "CDLL", return_value=libc), patch.object(
                xattrs.ctypes, "get_errno", return_value=errno.ERANGE):
            with self.assertRaises(OSError):
                xattrs.darwin_xattrs(self.work)
        self.assertEqual(libc.listxattr.call_count, 6)

    def test_linux_user_xattr_blocks_retirement_without_following_symlinks(self):
        if xattrs.sys.platform != "linux":
            self.skipTest("requires Linux extended attributes")
        target = self.work / "mixed.txt"
        os.setxattr(target, "user.must-preserve", b"local metadata")
        link = self.work / "link"
        link.symlink_to(target.name)
        self.assertEqual(xattrs.list_xattrs(link), [])
        with self.assertRaisesRegex(ValueError, "retirement:unsupported-metadata"):
            inventory(self.work)

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
