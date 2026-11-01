"""Local delta verification must not trust missing payloads via source alternates."""

import hashlib
import json
import unittest

from tests import test_preservation as fixtures


class LocalArchiveVerification(unittest.TestCase):
    setUp = fixtures.PreservationContract.setUp
    command = fixtures.PreservationContract.command
    git = fixtures.PreservationContract.git
    helper = fixtures.PreservationContract.helper
    archive = fixtures.PreservationContract.archive
    restore = fixtures.PreservationContract.restore

    def rewrite_inventory(self, archive, name, remove=False):
        path = archive / "manifest.json"
        manifest = json.loads(path.read_text())
        if remove:
            manifest["artifacts"] = [
                entry for entry in manifest["artifacts"] if entry["name"] != name
            ]
        else:
            payload = (archive / name).read_bytes()
            for entry in manifest["artifacts"]:
                if entry["name"] == name:
                    entry.update(size=len(payload),
                                 sha256=hashlib.sha256(payload).hexdigest())
        path.write_text(json.dumps(manifest))

    def test_delta_verifies_and_restores_without_full_audit_during_verification(self):
        (self.work / "mixed").write_text("staged\n")
        self.git(self.work, "add", "mixed")
        (self.work / "mixed").write_text("working\n")
        (self.work / "new-file").write_text("untracked\n")
        archive = self.archive()
        trace = self.root / "git-trace.log"
        self.env["GIT_TRACE"] = str(trace)
        self.helper("verify-local", archive)
        commands = trace.read_text()
        for forbidden in (" fsck", " checkout", " upload-pack", " fetch"):
            self.assertNotIn(forbidden, commands)
        self.env.pop("GIT_TRACE")
        restored, _ = self.restore(archive)
        self.assertEqual((restored / "mixed").read_text(), "working\n")
        self.assertEqual((restored / "new-file").read_text(), "untracked\n")
        self.assertEqual((restored / "local-commit").read_text(), "only local\n")

    def test_source_objects_do_not_hide_missing_unique_bundle(self):
        archive = self.archive()
        (archive / "commits.bundle").unlink()
        self.rewrite_inventory(archive, "commits.bundle", remove=True)
        result = self.helper("verify-local", archive, check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_corrupt_bundle_fails_even_with_updated_artifact_hash(self):
        archive = self.archive()
        bundle = archive / "commits.bundle"
        payload = bundle.read_bytes()
        bundle.write_bytes(payload[:-1] + bytes([payload[-1] ^ 1]))
        self.rewrite_inventory(archive, "commits.bundle")
        result = self.helper("verify-local", archive, check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_missing_patch_fails_even_with_updated_artifact_hash(self):
        (self.work / "mixed").write_text("must survive\n")
        archive = self.archive()
        (archive / "diff.patch").write_bytes(b"")
        self.rewrite_inventory(archive, "diff.patch")
        result = self.helper("verify-local", archive, check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_conflicted_merge_verifies_and_restores(self):
        (self.repo / "mixed").write_text("upstream\n")
        self.git(self.repo, "commit", "-qam", "upstream change")
        (self.work / "mixed").write_text("local\n")
        self.git(self.work, "commit", "-qam", "local change")
        result = self.command("git", "-C", self.work, "merge", "develop", check=False)
        self.assertEqual(result.returncode, 1)
        archive = self.archive()
        self.helper("verify-local", archive)
        restored, _ = self.restore(archive)
        self.assertEqual((restored / "mixed").read_bytes(),
                         (self.work / "mixed").read_bytes())
        self.assertEqual(self.git(restored, "ls-files", "--stage", "-z"),
                         self.git(self.work, "ls-files", "--stage", "-z"))

    def test_unknown_policy_is_rejected(self):
        archive = self.archive()
        path = archive / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["capture_policy"] = "unknown-policy"
        path.write_text(json.dumps(manifest))
        result = self.helper("verify-local", archive, check=False)
        self.assertNotEqual(result.returncode, 0)
