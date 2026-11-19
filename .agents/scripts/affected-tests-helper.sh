#!/usr/bin/env bash
# Select affected shell suites and distinguish regressions from inherited or flaky failures.
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
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

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
parser.add_argument("--retries", type=int, default=2,
                    help="reruns for a would-be regression before it counts; 0 disables")
args = parser.parse_args()
if min(args.max, args.jobs, args.timeout) < 1:
    parser.error("--max, --jobs and --timeout must be positive")
if args.retries < 0:
    parser.error("--retries must be zero or positive")

root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
os.chdir(root)
merge_base = subprocess.run(["git", "merge-base", args.base, "HEAD"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
diff_base = merge_base.stdout.strip() if merge_base.returncode == 0 and merge_base.stdout.strip() else args.base
# Working tree vs merge-base: committed, staged and unstaged edits, plus untracked scripts.
changed = subprocess.check_output(["git", "diff", "--name-only", diff_base, "--", ".agents/scripts"], text=True).splitlines()
changed += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "--", ".agents/scripts"], text=True).splitlines()
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
# Sourced-only modules define functions and exit 0 when run alone (a vacuous pass).
# Replace each selected module with the root suite(s) that transitively source it.
source_line = re.compile(r"^\s*(?:source|\.)\s+(.*)$")
sourcers = {}
for test in tests:
    rel = str(test.relative_to(root))
    for line in test.read_text(errors="replace").splitlines():
        match = source_line.match(line)
        if not match:
            continue
        for other in tests:
            if other != test and other.name in match.group(1):
                sourcers.setdefault(str(other.relative_to(root)), set()).add(rel)

def resolve_roots(module):
    roots, visited, stack = set(), {module}, [module]
    while stack:
        for parent in sorted(sourcers.get(stack.pop(), ())):
            if parent in visited:
                continue
            visited.add(parent)
            if parent in sourcers:
                stack.append(parent)
            else:
                roots.add(parent)
    return roots

resolved = set()
for suite in sorted(selected):
    roots = resolve_roots(suite) if suite in sourcers else set()
    if roots:
        print("module %s -> %s" % (suite, ", ".join(sorted(roots))), file=sys.stderr)
        resolved |= roots
    else:
        resolved.add(suite)
ordered = sorted(resolved)
omitted = ordered[args.max:]
overflow = len(omitted)
ordered = ordered[:args.max]
print("Affected suites: %d selected, %d omitted by cap" % (len(ordered), overflow), file=sys.stderr)
if omitted:
    print("omitted by cap: %s" % ", ".join(omitted), file=sys.stderr)
if args.command == "list":
    print("\n".join(ordered)) if ordered else None
    sys.exit(0)

stop = threading.Event()
running = set()
running_lock = threading.Lock()

def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass

def execute(item):
    directory, suite = item
    if stop.is_set() or not (directory / suite).is_file():
        return None
    with running_lock:
        if stop.is_set():
            return None
        proc = subprocess.Popen(["bash", suite], cwd=directory, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
        running.add(proc)
    try:
        return proc.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        kill_group(proc)
        proc.wait()
        return 124
    finally:
        with running_lock:
            running.discard(proc)

def cancel_all():
    with running_lock:
        stop.set()
        active = list(running)
    for proc in active:
        kill_group(proc)
    for proc in active:
        proc.wait()

def run_all(directory, suites):
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs)
    try:
        return dict(zip(suites, pool.map(execute, ((directory, s) for s in suites))))
    except BaseException:
        cancel_all()
        raise
    finally:
        pool.shutdown(wait=True, cancel_futures=stop.is_set())

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

# GH#38964: a would-be regression that passes on a head rerun is timing-dependent
# (e.g. SIGPIPE under pipefail), not caused by the change. Timeouts and
# pre-existing failures are not rerun, and a rerun that times out stops the
# retries: they are the expensive cases.
attempts = {suite: [head[suite]] for suite in ordered}
pending = [s for s in ordered if head[s] not in (0, 124) and base.get(s) in (None, 0)]
for _ in range(args.retries):
    if not pending:
        break
    rerun = run_all(root, pending)
    for suite in pending:
        attempts[suite].append(rerun[suite])
    pending = [s for s in pending if rerun[s] not in (0, 124)]

print("suite\trc_head\trc_base\tclass")
regression = False
for suite in ordered:
    rc = head[suite]
    baseline = base.get(suite)
    if rc == 0:
        classification = "pass"
    elif baseline is not None and baseline != 0:
        classification = "pre-existing"
    elif 0 in attempts[suite][1:]:
        classification = "flaky"
    else:
        classification = "regression"
        regression = True
    rc_text = ",".join("-" if value is None else str(value) for value in attempts[suite])
    print("%s\t%s\t%s\t%s" % (suite, rc_text, baseline if baseline is not None else "-", classification))
sys.exit(1 if regression else 0)
PY
