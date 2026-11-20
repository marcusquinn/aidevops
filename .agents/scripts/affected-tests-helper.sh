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
parser.add_argument("command", choices=("list", "run", "all"))
parser.add_argument("--base")
parser.add_argument("--max", type=int, default=30)
parser.add_argument("--jobs", type=int, default=4)
parser.add_argument("--timeout", type=int, default=240)
parser.add_argument("--max-hops", type=int, default=3,
                    help="sourcing hops to follow from a changed script; 0 disables")
parser.add_argument("--ubiquity", type=float, default=0.1,
                    help="scripts sourced by more than this share of scripts are not expanded")
parser.add_argument("--compare-base", action="store_true")
parser.add_argument("--retries", type=int, default=2,
                    help="reruns for a would-be regression before it counts; 0 disables")
args = parser.parse_args()
if args.command != "all" and not args.base:
    parser.error("--base is required for list and run")
if min(args.max, args.jobs, args.timeout) < 1:
    parser.error("--max, --jobs and --timeout must be positive")
if args.max_hops < 0:
    parser.error("--max-hops must be zero or positive")
if args.retries < 0:
    parser.error("--retries must be zero or positive")

def find_tracking_issue(title):
    """Return (number, url) of an open red-main issue, or None."""
    gh_path = shutil.which("gh")
    if not (gh_path and (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))):
        return None
    jq = r'.[] | select(.title == "%s") | "\(.number) \(.url)"' % title
    gh_args = [gh_path] + "issue list --state open --search".split() + ['"%s" in:title' % title,
               "--json", "number,title,url", "--jq", jq]
    try:
        # Fixed argv, absolute gh path, no shell; title derives from a repo suite filename.
        proc = subprocess.run(  # nosec B603
            gh_args, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
        out = proc.stdout.split()
    except (subprocess.SubprocessError, OSError):
        return None
    return (out[0], out[1]) if len(out) >= 2 else None


def report_inherited_red(suite):
    """t19150: point reviewers at the tracking issue for inherited red."""
    title = "red-main: %s" % Path(suite).name
    link = "search open issues for '%s'" % title
    found = find_tracking_issue(title)
    if found:
        link = "tracked by #%s" % found[0]
        links_file = os.environ.get("AFFECTED_TESTS_LINKS_FILE")
        if links_file:
            with open(links_file, "a", encoding="utf-8") as handle:
                handle.write("- `%s` is red on base: [#%s](%s)\n" % (Path(suite).name, found[0], found[1]))
    print("  inherited red %s: %s" % (suite, link), file=sys.stderr)


root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
os.chdir(root)
if args.command == "all":
    args.base = "HEAD"  # t19150: no base comparison; keeps the git calls below unchanged
merge_base = subprocess.run(["git", "merge-base", args.base, "HEAD"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
diff_base = merge_base.stdout.strip() if merge_base.returncode == 0 and merge_base.stdout.strip() else args.base
# Working tree vs merge-base: committed, staged and unstaged edits, plus untracked scripts.
changed = subprocess.check_output(["git", "diff", "--name-only", diff_base, "--", ".agents/scripts", "aidevops.sh"], text=True).splitlines()
changed += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "--", ".agents/scripts", "aidevops.sh"], text=True).splitlines()
if args.command == "all":
    changed = []
tests = sorted(root.glob(".agents/scripts/tests/test-*.sh"))
test_bytes = {str(t.relative_to(root)): t.read_bytes() for t in tests}
source_line = re.compile(r"^\s*(?:source|\.)\s+(.*)$")
script_token = re.compile(r"[A-Za-z0-9_.-]+\.sh")
# GH#39221: reverse sourcing graph over production scripts (sourced -> sourcers),
# so a changed shared library also selects suites naming its transitive consumers.
scripts = [p for p in sorted(root.glob(".agents/scripts/*.sh")) if p.is_file()]
script_names = {p.name for p in scripts}
# A changed script may be deleted: keep its name in the graph so remaining sourcers are traversed.
scripts_dir = Path(root, ".agents", "scripts").relative_to(root)
graph_names = script_names | {Path(c).name for c in changed
                              if Path(c).parent == scripts_dir and c.endswith(".sh")}
consumers = {}
for script in scripts:
    for line in script.read_text(errors="replace").splitlines():
        match = source_line.match(line)
        if match:
            for token in set(script_token.findall(match.group(1))):
                if token in graph_names and token != script.name:
                    consumers.setdefault(token, set()).add(script.name)
ubiquitous = {"shared-constants.sh"}
ubiquitous |= {n for n, c in consumers.items() if len(c) > args.ubiquity * len(scripts)}

def sourcer_distances(name):
    seen, frontier, hop = {name: 0}, [name], 0
    while frontier and hop < args.max_hops:
        hop += 1
        nxt = []
        for current in frontier:
            if current in ubiquitous:
                continue
            for parent in sorted(consumers.get(current, ())):
                if parent not in seen:
                    seen[parent] = hop
                    nxt.append(parent)
        frontier = nxt
    return seen

distance = {}
def select(suite, rank):
    distance[suite] = min(rank, distance.get(suite, rank))

for name in changed:
    path = Path(name)
    if path.parent == Path(".agents/scripts/tests") and path.name.startswith("test-") and path.suffix == ".sh":
        if (root / path).is_file():
            select(str(path), (False, 0, 0))
    # GH#39235: JS/TS runtimes (e.g. playwright-runtime.mjs) are exercised by
    # shell suites that name them; select those suites like .py (name match, hop 0).
    elif path.suffix in (".sh", ".py", ".mjs", ".cjs", ".js", ".ts") and "tests" not in path.parts:
        if path.parent.name == "scripts" and path.suffix == ".sh" and path.name in graph_names:
            related = sourcer_distances(path.name)
        else:
            related = {path.name: 0}
        # Within a hop, suites naming rarely-referenced scripts are the more specific signal.
        specificity = {n: sum(1 for b in test_bytes.values() if n.encode() in b) for n in related}
        for rel, blob in test_bytes.items():
            for related_name, hops in related.items():
                if related_name.encode() in blob:
                    select(rel, (hops > 0, specificity[related_name], hops))
selected = set(distance)
# Sourced-only modules define functions and exit 0 when run alone (a vacuous pass).
# Replace each selected module with the root suite(s) that transitively source it.
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

resolved = {}
for suite in sorted(selected):
    roots = resolve_roots(suite) if suite in sourcers else set()
    if roots:
        print("module %s -> %s" % (suite, ", ".join(sorted(roots))), file=sys.stderr)
    for target in (roots or {suite}):
        resolved[target] = min(distance[suite], resolved.get(target, distance[suite]))
ordered = sorted(resolved, key=lambda suite: (resolved[suite], suite))
if args.command == "all":
    # t19150: scheduled main-health mode: every root suite, no cap, no base comparison.
    # Sourced-only modules (no standalone entry) are skipped; their root suites exercise them.
    # Dual-use suites (sourced AND runnable: top-level main/exit or a BASH_SOURCE guard) stay.
    standalone = re.compile(r"^(?:main\b|exit\b)|BASH_SOURCE\[0\]", re.M)
    ordered = []
    for t in tests:
        rel = str(t.relative_to(root))
        if rel not in sourcers or standalone.search(test_bytes[rel].decode(errors="ignore")):
            ordered.append(rel)
    args.max = max(args.max, len(ordered))
    args.compare_base = False
    resolved = {suite: (False, 0, 0) for suite in ordered}
omitted = ordered[args.max:]
overflow = len(omitted)
ordered = ordered[:args.max]
print("Affected suites: %d selected, %d omitted by cap" % (len(ordered), overflow), file=sys.stderr)
counts = {}
for _, _, hops in resolved.values():
    counts[hops] = counts.get(hops, 0) + 1
print("by hop distance: %s" % ", ".join("%d=%d" % (k, counts[k]) for k in sorted(counts)), file=sys.stderr)
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

def run_all(directory, suites, jobs=None):
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=jobs or args.jobs)
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
#
# GH#39472: in `all` mode (parallel full-suite run on a shared runner) a timeout is
# most often load, so timeouts are rerun too, serially when the set is small
# (<= 20; a larger set signals a runner/environment storm, not suite defects).
# Reruns after the first stop on a timeout, which bounds the cost.
retry_codes = (0,) if args.command == "all" else (0, 124)
pending = [s for s in ordered if head[s] not in retry_codes and base.get(s) in (None, 0)]
rerun_jobs = 1 if args.command == "all" and len(pending) <= 20 else None
for _ in range(args.retries):
    if not pending:
        break
    rerun = run_all(root, pending, rerun_jobs)
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
    if classification == "pre-existing":
        report_inherited_red(suite)
sys.exit(1 if regression else 0)
PY
