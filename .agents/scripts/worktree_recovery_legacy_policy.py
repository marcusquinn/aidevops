#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Legacy Pulse naming/age policy, never a fabricated lifetime receipt.

Only compact-then-retire uses this fallback for degraded CWD observation.
Positive activity, unusable observation and raw-copy expiry remain protected.
"""

from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time

from worktree_lifetime_archive import require
from worktree_recovery_legacy_report import age_seconds, legacy_decision, legacy_origin


def candidate(identity):
    origin = legacy_origin(identity["source_path"], identity["producer"], identity["producer_context"])
    age = age_seconds(identity["created_at"], time.time())
    return legacy_decision(origin, age) == "eligible-legacy-pulse"


def has_lifecycle(identity):
    directory = Path(os.environ.get("WORKTREE_REGISTRY_DIR") or Path.home() / ".aidevops/.agent-workspace")
    db_path = Path(os.environ.get("WORKTREE_REGISTRY_DB") or directory / "worktree-registry.db")
    require(db_path.is_file() and not db_path.is_symlink(), "legacy-pulse:registry-unavailable")
    try:
        with closing(sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            row = db.execute("SELECT 1 FROM worktree_managed_lifetimes WHERE path=?",
                             (identity["source_path"],)).fetchone()
    except sqlite3.Error as error:
        raise ValueError("legacy-pulse:registry-unavailable") from error
    return row is not None


def validate(identity):
    require(identity["format"] == "aidevops-worktree-recovery-v2"
            and identity["producer"] == "worktree-helper.sh"
            and identity["producer_context"] == "recoverable-cleanup"
            and identity["source_removal_outcome"] == "removed", "legacy-pulse:wrong-source-policy")
    require(candidate(identity), "legacy-pulse:name-or-age-ineligible")
    # The base must survive deletion, including symlinks into the source bucket.
    common = Path(identity["common_path"]).resolve(strict=True)
    bucket = Path(identity["bucket_path"]).resolve()
    require(not common.is_relative_to(bucket), "legacy-pulse:base-inside-source")
    require(not has_lifecycle(identity), "legacy-pulse:use-existing-lifecycle")


def guards(identity, target, lock=None):
    bash = shutil.which("bash")
    require(bash is not None, "retirement:bash-unavailable")
    helper = Path(__file__).with_name("worktree-recovery-lifecycle-helper.sh")
    arguments = [str(Path(bash).absolute()), str(helper), "retirement-guard", str(target)]
    result = subprocess.run(  # nosec B603 -- fixed local guard, argv only, no shell
        arguments, input=json.dumps(identity), text=True, capture_output=True,
        pass_fds=() if lock is None else (lock,), timeout=120, check=False)
    require(result.returncode == 0, "retirement:" + (result.stdout.strip() or "guard-unavailable"))


def main():
    try:
        validate(json.load(sys.stdin))
        return 0
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error):
        print("legacy-pulse:policy-evidence-unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
