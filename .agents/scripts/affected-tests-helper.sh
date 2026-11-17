#!/usr/bin/env bash
# Select affected shell suites and distinguish regressions from inherited failures.
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

python3 - "$@" <<'PY'
import argparse
import concurrent.futures
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

def interrupted(signum, frame):
    raise KeyboardInterrupt("signal %s" % signum)

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)

parser = argparse.ArgumentParser(description="Run suites referencing changed scripts")
parser.add_argument("command", choices=("list", "run"))
parser.add_argument("--base", required=True)
parser.add_argument("--max", type=int, default=30)
parser.add_argument("--jobs", type=int, default=4)
parser.add_argument("--timeout", type=int, default=240)
parser.add_argument("--compare-base", action="store_true")
args = parser.parse_args()
if min(args.max, args.jobs, args.timeout) < 1:
    parser.error("--max, --jobs and --timeout must be positive")

root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
os.chdir(root)
changed = subprocess.check_output(["git", "diff", "--name-only", args.base + "...HEAD", "--", ".agents/scripts"], text=True).splitlines()
tests = sorted(root.glob(".agents/scripts/tests/test-*.sh"))
selected = set()
for name in changed:
    path = Path(name)
    if path.parent == Path(".agents/scripts/tests") and path.name.startswith("test-") and path.suffix == ".sh":
        if (root / path).is_file():
            selected.add(str(path))
    elif path.suffix in (".sh", ".py") and "tests" not in path.parts:
        for test in tests:
            if path.name.encode() in test.read_bytes():
                selected.add(str(test.relative_to(root)))
ordered = sorted(selected)
overflow = max(0, len(ordered) - args.max)
ordered = ordered[:args.max]
print("Affected suites: %d selected, %d omitted by cap" % (len(ordered), overflow), file=sys.stderr)
if args.command == "list":
    print("\n".join(ordered)) if ordered else None
    sys.exit(0)

def execute(item):
    directory, suite = item
    if not (directory / suite).is_file():
        return None
    proc = subprocess.Popen(["bash", suite], cwd=directory, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        return proc.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        return 124

def run_all(directory, suites):
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        return dict(zip(suites, pool.map(execute, ((directory, s) for s in suites))))

head = run_all(root, ordered)
failed = [s for s in ordered if head[s] != 0]
base = {}
if failed and args.compare_base:
    parent = Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR", str(Path.home() / "Git/_worktrees")))
    parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="affected-tests-", dir=str(parent)))
    worktree = temporary / "base"
    try:
        subprocess.run(["git", "worktree", "add", "--detach", str(worktree), args.base], check=True, stdout=subprocess.DEVNULL)
        base = run_all(worktree, failed)
    finally:
        if worktree.exists():
            subprocess.run(["git", "worktree", "remove", "--force", str(worktree)], check=True)
        shutil.rmtree(temporary)

print("suite\trc_head\trc_base\tclass")
regression = False
for suite in ordered:
    rc = head[suite]
    baseline = base.get(suite)
    if rc == 0:
        classification = "pass"
    elif baseline is not None and baseline != 0:
        classification = "pre-existing"
    else:
        classification = "regression"
        regression = True
    print("%s\t%s\t%s\t%s" % (suite, rc, baseline if baseline is not None else "-", classification))
sys.exit(1 if regression else 0)
PY
