#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Exercise the production syntax gate against partial staging (GH#36702).

Substitute the host Bash on Linux: this tests index selection and failure
handling, not Bash 3.2 parser compatibility (covered by the pinned CI image).
"""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile


def main():
    """Check staged content independently of working-tree content."""
    source = (Path(__file__).resolve().parents[1] / "pre-commit-hook.sh").read_text()
    function = (
        "validate_bash32_parse() {"
        + source.split("validate_bash32_parse() {", 1)[1].split("\n}\n", 1)[0]
        + "\n}\n"
    )
    bash = shutil.which("bash")
    assert bash, "Bash is required"
    # Bypass only the host-version guard, keeping production index/error logic.
    guard = '[[ "$major" == "3" ]] || return 0'
    assert guard in function, "Update the test for the changed host-version guard"
    function = function.replace(guard, ":").replace("/bin/bash", bash)
    temp_root = Path(
        os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp"))
    )
    temp_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bash32-staged-", dir=temp_root) as directory:
        def git(*args):
            return subprocess.run(
                ["git", *args], cwd=directory, check=True, capture_output=True, text=True
            )

        git("init", "-q")
        path = Path(directory) / "partial staging.sh"
        script = (
            'print_info() { :; }; print_error() { printf "%s\\n" "$*" >&2; };\n'
            + function
            + "validate_bash32_parse "
            + shlex.quote(path.name)
        )

        def run_gate():
            return subprocess.run(
                [bash, "-c", script], cwd=directory, capture_output=True, text=True
            )

        cases = [
            ("true\n", "if then\n", 0, "valid staged / invalid unstaged"),
            ("if then\n", "true\n", 1, "invalid staged / valid unstaged"),
            ("true\n", None, 0, "absent working-tree file"),
        ]
        for staged, working, expected, label in cases:
            path.write_text(staged)
            git("add", "--", path.name)
            if working is None:
                path.unlink()
            else:
                path.write_text(working)
            result = run_gate()
            assert result.returncode == expected, (label, result.stderr)
            if expected:
                assert path.name in result.stderr, "Failure must identify the staged file"
            print(f"PASS: {label} (filename contains spaces)")

        git("rm", "--cached", "--", path.name)
        result = run_gate()
        assert result.returncode != 0, "Missing index blob must fail closed"
        assert path.name in result.stderr, "Read failure must identify the staged file"
        print("PASS: missing index blob fails closed")


if __name__ == "__main__":
    main()
