"""Test-only registry launcher with synthetic, root-scoped process references.

Keep native process identity/admission, archive and Git removal paths intact.
Only the unrelated host-wide census is replaced, using the same synthetic proc
contract as worker-lifecycle/tests/test_legacy_cleanup.py. Never install this
launcher in a production PATH or substitute evidence for a real host tree.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import os
from pathlib import Path
import runpy
import sys
import tempfile
from unittest.mock import patch


def main():
    root = Path(os.environ["LIFECYCLE_FIXTURE_ROOT"]).resolve(strict=True)
    entry = Path(os.environ["LIFECYCLE_FIXTURE_ENTRY"]).resolve(strict=True)
    if (root.stat().st_uid != os.geteuid() or root == Path(root.anchor)
            or root.stat().st_mode & 0o077):
        raise ValueError("fixture-root-invalid")
    sys.path.insert(0, str(entry.parent))
    from worker_lifecycle import legacy_proc, protected_proc

    with tempfile.TemporaryDirectory(prefix="process-census-", dir=root) as temporary:
        proc = Path(temporary)
        task = proc / "123" / "task" / "123"
        (task / "fd").mkdir(parents=True)
        (proc / "self").mkdir()
        (task / "cwd").symlink_to(proc, target_is_directory=True)
        uid = os.geteuid()
        (task / "status").write_text(
            f"Name:\tfixture\nState:\tS\nUid:\t{uid} {uid} {uid} {uid}\n"
        )

        def census(path):
            candidate = Path(path).resolve(strict=True)
            if root not in candidate.parents:
                raise ValueError("fixture-candidate-outside-root")
            legacy_proc.require_idle_proc(candidate, proc)
            if sys.argv[1:] != ["--self-test"]:
                with (root / "fixture-census.log").open("a", encoding="utf-8") as log:
                    log.write("synthetic-census\n")

        if sys.argv[1:] == ["--self-test"]:
            candidate = proc / "candidate"
            candidate.mkdir()
            census(candidate)
            try:
                census(root.parent)
            except ValueError as error:
                assert str(error) == "fixture-candidate-outside-root"
            else:
                raise AssertionError("out-of-root candidate accepted")
            (proc / "self").rmdir()
            try:
                census(candidate)
            except ValueError as error:
                assert str(error) == "proc-observation-unavailable"
            else:
                raise AssertionError("missing census accepted")
            (proc / "self").mkdir()
            (task / "cwd").unlink()
            (task / "cwd").symlink_to(candidate, target_is_directory=True)
            try:
                census(candidate)
            except ValueError as error:
                assert str(error) == "live-process-reference"
            else:
                raise AssertionError("held candidate accepted")
            # Exercise the real opt-in boundary without inspecting any process.
            with patch.dict(os.environ, {protected_proc.OPT_IN: "0"}):
                try:
                    protected_proc.privileged_path_census(candidate)
                except protected_proc.ProcessCensusUnavailable as error:
                    assert error.observation["cause"] == "inspection-not-enabled"
                else:
                    raise AssertionError("protected census accepted without opt-in")
            print("PASS fixture census refuses missing evidence, held trees, outside roots and protected inspection")
            return 0

        # Patch before registry imports bind require_idle_processes into callers.
        with patch.object(legacy_proc, "require_idle_processes", census):
            sys.argv[0] = str(entry)
            runpy.run_path(str(entry), run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
