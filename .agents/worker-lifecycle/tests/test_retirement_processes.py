"""Native retirement process census dispatch and macOS field parsing."""

import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from worker_lifecycle import legacy_proc, retirement


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
        with patch.object(legacy_proc.subprocess, "run", return_value=result):
            legacy_proc.require_idle_macos(Path("/work/tree with\nnewline"))

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
        with patch.object(legacy_proc.subprocess, "run", side_effect=FileNotFoundError):
            with self.assertRaisesRegex(ValueError, "proc-observation-unavailable"):
                legacy_proc.require_idle_macos(Path("/work/tree"))

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
