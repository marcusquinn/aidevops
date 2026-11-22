#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GH#35673 lossless historical Markdown archive; synthetic fixtures only."""

import hashlib
import importlib.util
import json
import subprocess  # nosec B404
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
HELPER = SCRIPTS / "historical-markdown-archive.py"
SPEC = importlib.util.spec_from_file_location("historical_markdown_archive", HELPER)
hma = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hma)

MIXED = (b"\xef\xbb\xbf# Title\r\n" + b"".join(b"bad \xff\xfe line %d\r\n" % i for i in range(9))
         + b"```\nunclosed fence\n" + b"no final newline")


class ArchiveTestCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def source(self, data, name="history.md"):
        path = self.root / name
        path.write_bytes(data)
        return path

    def archive(self, data, max_lines=hma.DEFAULT_MAX_LINES, name="arc"):
        source = self.source(data)
        dest = self.root / name
        manifest = hma.archive(str(source), str(dest), max_lines)
        return source, dest, manifest

    def rebuild(self, dest):
        manifest = json.loads((dest / "manifest.json").read_text())
        return b"".join((dest / entry["path"]).read_bytes() for entry in manifest["parts"])

    def edit_manifest(self, dest, change):
        path = dest / "manifest.json"
        manifest = json.loads(path.read_text())
        change(manifest)
        path.write_text(json.dumps(manifest))

    def assert_refused(self, pattern, func, *args, **kwargs):
        with self.assertRaisesRegex(hma.ArchiveError, pattern):
            func(*args, **kwargs)

    def leftovers(self):
        return sorted(p.name for p in self.root.iterdir() if p.name.startswith(".arc"))


class RoundTripTests(ArchiveTestCase):
    def test_round_trips_and_bounds(self):
        cases = {
            "multiline": (b"".join(b"line %d\n" % i for i in range(1000)), 400, [400, 400, 200]),
            "exact boundary": (b"x\n" * 800, 400, [400, 400]),
            "boundary plus one": (b"x\n" * 401, 400, [400, 1]),
            "single line": (b"only line", 400, [1]),
            "empty": (b"", 400, [0]),
            "bom crlf invalid utf8 no final lf": (MIXED, 4, [4, 4, 4, 1]),
            "oversized single line": (b"a" * 200000, 400, [1]),
        }
        for label, (data, limit, lines) in cases.items():
            with self.subTest(label):
                source, dest, manifest = self.archive(data, limit, name=f"arc-{len(lines)}-{limit}-{len(data)}")
                self.assertEqual([p["lines"] for p in manifest["parts"]], lines)
                self.assertEqual(self.rebuild(dest), data)
                self.assertEqual(manifest["source"]["sha256"], hashlib.sha256(data).hexdigest())
                self.assertEqual(manifest["source"]["label"], "source.md")
                self.assertEqual(manifest["source"]["lf_count"], data.count(b"\n"))
                hma.verify(str(dest), original=str(source))
                self.assertEqual(source.read_bytes(), data)

    def test_output_is_deterministic_and_source_untouched(self):
        source = self.source(MIXED)
        before = source.stat()
        for name in ("one", "two"):
            hma.archive(str(source), str(self.root / name), 3)
        files = sorted(p.name for p in (self.root / "one").iterdir())
        self.assertEqual(files, sorted(p.name for p in (self.root / "two").iterdir()))
        for name in files:
            self.assertEqual((self.root / "one" / name).read_bytes(), (self.root / "two" / name).read_bytes())
        after = source.stat()
        self.assertEqual((before.st_mtime_ns, before.st_size), (after.st_mtime_ns, after.st_size))
        readme = (self.root / "one" / "README.md").read_text()
        self.assertIn("not canonical and not active guidance", readme)
        self.assertNotIn("history.md", readme + (self.root / "one" / "manifest.json").read_text())

    def test_verify_without_original_reports_integrity_scope(self):
        _, dest, _ = self.archive(b"a\nb\n")
        self.assertEqual(hma.verify(str(dest))["source"]["bytes"], 4)
        other = self.source(b"a\nB\n", name="other.md")
        self.assert_refused("differs from the reconstruction at byte offset 2",
                            hma.verify, str(dest), original=str(other))


class ArchiveRefusalTests(ArchiveTestCase):
    def test_refuses_existing_or_symlinked_destinations(self):
        source = self.source(b"a\n")
        (self.root / "dir").mkdir()
        (self.root / "file").write_bytes(b"keep")
        (self.root / "dangling").symlink_to(self.root / "missing")
        (self.root / "dirlink").symlink_to(self.root / "dir")
        for name in ("dir", "file", "dangling", "dirlink"):
            with self.subTest(name):
                self.assert_refused("already exists", hma.archive, str(source), str(self.root / name))
        self.assertEqual((self.root / "file").read_bytes(), b"keep")
        self.assertEqual(list((self.root / "dir").iterdir()), [])
        self.assert_refused("already exists", hma.archive, str(source), str(source))
        self.assert_refused("parent is not an existing directory",
                            hma.archive, str(source), str(self.root / "missing" / "arc"))

    def test_refuses_unsafe_sources_and_options(self):
        real = self.source(b"a\n")
        (self.root / "link.md").symlink_to(real)
        (self.root / "folder.md").mkdir()
        self.assert_refused("must not be a symlink", hma.archive, str(self.root / "link.md"), str(self.root / "a"))
        self.assert_refused("not a regular file", hma.archive, str(self.root / "folder.md"), str(self.root / "b"))
        self.assert_refused("Markdown file", hma.archive, str(self.source(b"a", "notes.txt")), str(self.root / "c"))
        self.assert_refused("positive integer", hma.archive, str(real), str(self.root / "d"), 0)
        self.assert_refused("plain, printable", hma.archive, str(real), str(self.root / "e"), 4, "../x.md")
        self.assertTrue(hma.paths_overlap(str(self.root), str(self.root / "arc")))
        self.assertFalse(hma.paths_overlap(str(real), str(self.root / "arc")))
        self.assertEqual(sorted(p.name for p in self.root.iterdir()),
                         ["folder.md", "history.md", "link.md", "notes.txt"])

    def test_interrupted_write_leaves_nothing_published(self):
        source = self.source(b"x\n" * 10)
        original = hma.write_new_file
        calls = []

        def failing(dir_fd, name, payload):
            calls.append(name)
            if len(calls) == 2:
                raise OSError("synthetic interrupted write")
            original(dir_fd, name, payload)

        with mock.patch.object(hma, "write_new_file", failing):
            with self.assertRaisesRegex(OSError, "synthetic interrupted write"):
                hma.archive(str(source), str(self.root / "arc"), 3)
        self.assertFalse((self.root / "arc").exists())
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(source.read_bytes(), b"x\n" * 10)

    def test_source_change_during_archive_is_refused(self):
        source = self.source(b"x\n" * 10)
        original = hma.write_new_file

        def mutate_after_manifest(dir_fd, name, payload):
            original(dir_fd, name, payload)
            if name == "manifest.json":
                with open(source, "ab") as handle:
                    handle.write(b"late edit\n")

        with mock.patch.object(hma, "write_new_file", mutate_after_manifest):
            self.assert_refused("differs|changed", hma.archive, str(source), str(self.root / "arc"), 3)
        self.assertFalse((self.root / "arc").exists())
        self.assertEqual(self.leftovers(), [])

    def test_source_change_after_staged_verify_is_refused(self):
        source = self.source(b"x\n" * 10)
        original = hma.verify_dir_fd

        def mutate_after_verify(dir_fd, **kwargs):
            result = original(dir_fd, **kwargs)
            source.write_bytes(b"y\n" * 10)
            return result

        with mock.patch.object(hma, "verify_dir_fd", mutate_after_verify):
            self.assert_refused("source changed during archiving", hma.archive, str(source), str(self.root / "arc"), 3)
        self.assertFalse((self.root / "arc").exists())
        self.assertEqual(self.leftovers(), [])


class VerifyTamperTests(ArchiveTestCase):
    def setUp(self):
        super().setUp()
        self.src, self.dest, _ = self.archive(b"".join(b"row %d\n" % i for i in range(10)), 3)

    def test_manifest_tampering_is_rejected_before_parts_are_read(self):
        def swap(m):
            m["parts"][0], m["parts"][1] = m["parts"][1], m["parts"][0]

        def set_path(value):
            return lambda m: m["parts"][0].__setitem__("path", value)

        cases = {
            "unsupported manifest schema": lambda m: m.__setitem__("schema", "other/v9"),
            "must be relative": set_path("/etc/passwd"),
            "traverses outside": set_path("../part-0001.md"),
            "plain part file name": set_path("sub/part-0001.md"),
            "duplicate part": lambda m: m["parts"][1].__setitem__("path", "part-0001.md"),
            "missing or reordered": swap,
            "missing or reordered at position 2": lambda m: m["parts"].pop(1),
            "keys must be exactly": lambda m: m["source"].__setitem__("extra", 1),
            "must be an integer": lambda m: m["parts"][0].__setitem__("lines", True),
            "64 lowercase hex": lambda m: m["parts"][0].__setitem__("sha256", "ABC"),
            "not contiguous": lambda m: m["parts"][1].__setitem__("first_line", 9),
        }
        for message, change in cases.items():
            with self.subTest(message):
                saved = (self.dest / "manifest.json").read_bytes()
                self.edit_manifest(self.dest, change)
                with mock.patch.object(hma, "read_parts", side_effect=AssertionError("parts read")):
                    self.assert_refused(message, hma.verify, str(self.dest))
                (self.dest / "manifest.json").write_bytes(saved)
        hma.verify(str(self.dest), original=str(self.src))

    def test_duplicate_json_keys_and_invalid_json(self):
        (self.dest / "manifest.json").write_text('{"schema": 1, "schema": 2}')
        self.assert_refused("duplicate key", hma.verify, str(self.dest))
        (self.dest / "manifest.json").write_text("{not json")
        self.assert_refused("not valid JSON", hma.verify, str(self.dest))

    def test_part_tampering_is_rejected(self):
        part = self.dest / "part-0002.md"
        saved = part.read_bytes()
        part.write_bytes(saved.replace(b"row", b"rov"))
        self.assert_refused("part 2 .* sha256 does not match", hma.verify, str(self.dest))
        part.unlink()
        self.assert_refused("part 2 not found", hma.verify, str(self.dest))
        (self.root / "elsewhere.md").write_bytes(saved)
        part.symlink_to(self.root / "elsewhere.md")
        self.assert_refused("part 2 must not be a symlink", hma.verify, str(self.dest))
        part.unlink()
        part.write_bytes(saved)
        (self.dest / "part-0009.md").write_bytes(b"stray\n")
        self.assert_refused("unlisted part files: part-0009.md", hma.verify, str(self.dest))
        (self.dest / "part-0009.md").unlink()
        hma.verify(str(self.dest), original=str(self.src))

    def test_symlinked_archive_and_manifest_are_rejected(self):
        link = self.root / "arc-link"
        link.symlink_to(self.dest)
        self.assert_refused("archive directory must not be a symlink", hma.verify, str(link))
        manifest = self.dest / "manifest.json"
        moved = self.root / "manifest-copy.json"
        moved.write_bytes(manifest.read_bytes())
        manifest.unlink()
        manifest.symlink_to(moved)
        self.assert_refused("manifest must not be a symlink", hma.verify, str(self.dest))


class CliTests(ArchiveTestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(HELPER), *args], capture_output=True,
                              text=True, timeout=60, check=False)  # nosec B603

    def test_help_and_exit_statuses(self):
        for args in ([], ["archive"], ["verify"]):
            with self.subTest(args):
                result = self.run_cli(*args, "--help")
                self.assertEqual(result.returncode, 0)
                self.assertIn("usage:", result.stdout)
        self.assertEqual(self.run_cli().returncode, 2)
        source = self.source(MIXED)
        dest = self.root / "arc"
        self.assertEqual(self.run_cli("archive", str(source), str(dest), "--max-lines", "0").returncode, 2)
        created = self.run_cli("archive", str(source), str(dest), "--max-lines", "5")
        self.assertEqual(created.returncode, 0, created.stderr)
        checked = self.run_cli("verify", str(dest))
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("integrity only", checked.stdout)
        equal = self.run_cli("verify", str(dest), "--original", str(source))
        self.assertIn("byte-for-byte equal", equal.stdout)
        again = self.run_cli("archive", str(source), str(dest))
        self.assertEqual(again.returncode, 1)
        self.assertIn("already exists", again.stderr)
        (dest / "part-0001.md").write_bytes(b"tampered")
        self.assertEqual(self.run_cli("verify", str(dest)).returncode, 1)

    def test_manual_cat_reconstruction_matches(self):
        source = self.source(MIXED)
        dest = self.root / "arc"
        self.assertEqual(self.run_cli("archive", str(source), str(dest), "--max-lines", "2").returncode, 0)
        names = [p["path"] for p in json.loads((dest / "manifest.json").read_text())["parts"]]
        result = subprocess.run(["cat", *names], cwd=dest, capture_output=True, timeout=60, check=True)  # nosec B603 B607
        self.assertEqual(result.stdout, MIXED)
        readme = (dest / "README.md").read_text()
        self.assertIn("  part-0001.md \\\n", readme)


if __name__ == "__main__":
    unittest.main()
