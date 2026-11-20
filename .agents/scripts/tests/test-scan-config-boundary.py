#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise the scan configuration boundary without real scanners or network."""

import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile


HELPER = Path(__file__).resolve().parents[1] / "secretlint-helper.sh"


def main():
    with tempfile.TemporaryDirectory(prefix="scan-config-boundary-") as temporary:
        root = Path(temporary)
        project = root / "project"
        binaries = root / "bin"
        project.mkdir()
        binaries.mkdir()
        calls = root / "calls"
        for name in ("npm", "npx", "docker", "secretlint"):
            stub = binaries / name
            stub.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$SCAN_CALL_LOG"\n'
                'case "$0" in */secretlint) [ -n "$SCAN_JSON" ] && cat "$SCAN_JSON"; exit "${SCAN_EXIT:-0}";; esac\n'
                'exit 0\n', encoding="utf-8"
            )
            stub.chmod(0o700)
        environment = {
            **os.environ,
            "PATH": f"{binaries}:{os.environ['PATH']}",
            "SCAN_CALL_LOG": str(calls),
        }

        def run(command, exit_code=0):
            return subprocess.run(
                ["bash", str(HELPER), command, "**/*", "json"],
                cwd=project, env={**environment, "SCAN_EXIT": str(exit_code)},
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                timeout=30, check=False,
            )

        # Both aliases and overlapping scans must fail before any setup or runner.
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(run, ["scan", "lint", "scan", "lint"]))
        for result in results:
            assert result.returncode == 2, result
            assert "init" in result.stdout + result.stderr, result
            assert "No secrets detected" not in result.stdout, result
        assert not list(project.iterdir()), "missing-config scans wrote project files"
        assert not calls.exists(), "missing-config scans invoked a runner or installer"

        # Explicit init remains the owner of configuration and ignore-file writes.
        # A failing scanner --init exercises the helper's existing config fallback.
        result = run("init", 1)
        assert result.returncode == 0, result
        config = project / ".secretlintrc.json"
        ignore = project / ".secretlintignore"
        assert config.is_file() and ignore.is_file(), result
        before = {path.name: path.read_bytes() for path in project.iterdir() if path.is_file()}
        if calls.exists():
            calls.unlink()
        for command, code in (("scan", 0), ("lint", 1), ("scan", 2)):
            result = run(command, code)
            assert result.returncode == code, result
        after = {path.name: path.read_bytes() for path in project.iterdir() if path.is_file()}
        assert before == after, "configured scans changed project files"
        assert "secretlint **/* --format json" in calls.read_text(encoding="utf-8")

        # Summary mode: content-free output, excluded = candidates - scanned.
        marker = "SYNTHETIC_FILE_BODY_MARKER"
        (project / "kept.txt").write_text(marker, encoding="utf-8")
        (project / "found.txt").write_text(marker, encoding="utf-8")
        (project / "skipped.txt").write_text(marker, encoding="utf-8")
        ignore.write_text(marker + "\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=project, check=True)
        subprocess.run(["git", "add", "-A"], cwd=project, check=True)
        scanned = json.dumps([
            {"filePath": str(project / "kept.txt"), "sourceContent": marker, "messages": []},
            {"filePath": str(project / "found.txt"), "sourceContent": marker, "messages": [
                {"ruleId": "synthetic-rule", "message": marker, "data": {"v": marker}, "range": [0, 1]},
                {"ruleId": "synthetic-rule", "message": marker, "range": [2, 3]},
            ]},
        ])
        results_file = root / "results.json"
        results_file.write_text(scanned, encoding="utf-8")
        summary_env = {**environment, "SCAN_JSON": str(results_file)}

        def summary(exit_code):
            return subprocess.run(
                ["bash", str(HELPER), "summary"], cwd=project,
                env={**summary_env, "SCAN_EXIT": str(exit_code)},
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                timeout=30, check=False,
            )

        result = summary(1)
        output = result.stdout + result.stderr
        assert result.returncode == 1, result
        assert marker not in output and "sourceContent" not in output, result
        assert "excluded-path: skipped.txt" in output, result
        assert "excluded-path: .secretlintignore" in output, result
        assert "finding: found.txt\tsynthetic-rule\t2" in output, result
        assert "scanned: 2" in output and "flagged: 1" in output, result
        result = summary(0)
        assert result.returncode == 1, "findings must not look clean"
        result = subprocess.run(
            ["bash", str(HELPER), "summary"], cwd=project,
            env={**environment, "SCAN_EXIT": "2"}, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30, check=False,
        )
        assert result.returncode == 2, result
        assert "scanned:" not in result.stdout, "fatal scan printed a summary"
        results_file.write_text("[]", encoding="utf-8")
        result = summary(0)
        assert result.returncode == 0 and "scanned: 0" in result.stdout, result
    print("PASS scan/lint missing config, concurrency, explicit init, configured exit codes, content-free summary")


if __name__ == "__main__":
    main()
