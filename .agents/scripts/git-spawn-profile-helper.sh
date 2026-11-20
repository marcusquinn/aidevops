#!/usr/bin/env bash
# Per-test Git-spawn attribution for the Python archive/lifecycle suites.
# Wall-clock timings are unusable on loaded hosts; per-test spawn counts are stable.
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Usage:
#   git-spawn-profile-helper.sh run <worktree> <out-dir> [test-name-filter...]
#   git-spawn-profile-helper.sh summary <log> [--top N]
#   git-spawn-profile-helper.sh compare <base-log> <head-log> [--completed <times.json>...]
#
# `run` writes <out-dir>/spawns.log (`<test>\t<argv>` per Git spawn) and
# <out-dir>/times.json (per-test wall time, completed tests only). Keep out-dir
# under ${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}.

set -u

main() {
	local command="${1:-}"
	if [[ "$command" == "-h" || "$command" == "--help" || -z "$command" ]]; then
		sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		return 0
	fi
	shift
	# The shim must exec the git resolved BEFORE any PATH modification, so any
	# earlier wrapper (e.g. .agents/scripts/git canonical guard) stays in force.
	local real_git
	real_git="$(command -v git 2>/dev/null || true)"
	GIT_SPAWN_REAL_GIT="$real_git" \
		GIT_SPAWN_DEFAULT_TMP="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}" \
		python3 - "$command" "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import sys
import time
import unittest
import importlib.util
from collections import Counter

SHIM = """#!/usr/bin/env bash
# git-spawn-profile shim: log the spawn, then exec the pre-shim git.
printf '%s\\t%s\\n' "${GIT_SPAWN_TEST:-untagged}" "$*" >> "$GIT_SPAWN_LOG"
exec "$GIT_SPAWN_REAL_GIT" "$@"
"""

TAG = "GIT_SPAWN_TEST"
FAILED = "failed_ids"

class TaggedResult(unittest.TextTestResult):
    def startTest(self, test):
        self._t0 = time.monotonic()
        os.environ[TAG] = test.id().split(".", 1)[-1] if "." in test.id() else test.id()
        super().startTest(test)

    def stopTest(self, test):
        super().stopTest(test)
        self.times = getattr(self, "times", {})
        self.times[os.environ[TAG]] = time.monotonic() - self._t0
        os.environ[TAG] = "untagged"

    def _mark(self, test):
        failed = getattr(self, FAILED, set())
        failed.add(os.environ.get(TAG, ""))
        setattr(self, FAILED, failed)

    def addError(self, test, err):
        self._mark(test)
        super().addError(test, err)

    def addFailure(self, test, err):
        self._mark(test)
        super().addFailure(test, err)

def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item

def cmd_run(args):
    worktree = Path(args.worktree).resolve()
    test_file = worktree / ".agents/scripts/tests/test-worktree-archive-lifecycle.py"
    real_git = os.environ.get("GIT_SPAWN_REAL_GIT", "")
    if not test_file.is_file():
        sys.exit("error: missing %s" % test_file)
    if not real_git:
        sys.exit("error: git not found on PATH")
    out = Path(args.out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    shim_dir = out / "shim"
    shim_dir.mkdir(exist_ok=True)
    shim = shim_dir / "git"
    shim.write_text(SHIM)
    shim.chmod(0o755)
    log = out / "spawns.log"
    log.write_text("")
    os.environ.update(GIT_SPAWN_LOG=str(log), GIT_SPAWN_REAL_GIT=real_git,
                      GIT_SPAWN_TEST="untagged")
    os.environ["PATH"] = str(shim_dir) + os.pathsep + os.environ.get("PATH", "")
    sys.path.insert(0, str(test_file.parent))
    sys.path.insert(0, str(test_file.parents[1]))
    spec = importlib.util.spec_from_file_location("archive_lifecycle_entry", test_file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    selected = unittest.TestSuite()
    for test in flatten(suite):
        if not args.filters or any(f in test.id() for f in args.filters):
            selected.addTest(test)
    if selected.countTestCases() == 0:
        sys.exit("error: no tests match %s" % args.filters)
    runner = unittest.TextTestRunner(resultclass=TaggedResult, verbosity=1, stream=sys.stderr)
    result = runner.run(selected)
    failed = getattr(result, "failed_ids", set())
    times = {k: round(v, 3) for k, v in getattr(result, "times", {}).items() if k not in failed}
    (out / "times.json").write_text(json.dumps(times, indent=1, sort_keys=True))
    print("log=%s times=%s spawns=%d tests=%d" % (
        log, out / "times.json", sum(1 for _ in log.open()), len(times)))
    if not log.stat().st_size:
        sys.exit("error: no Git spawns recorded (tests may override PATH)")

def shape_of(argv):
    words = argv.split()
    i = 0
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in ("-c", "-C", "--git-dir", "--work-tree") else 1
    return " ".join(words[i:i + 2])

def read_log(path):
    per_test = {}
    shapes = Counter()
    with open(path) as handle:
        for line in handle:
            test, _, argv = line.rstrip("\n").partition("\t")
            per_test.setdefault(test, Counter())[argv] += 1
            shapes[shape_of(argv)] += 1
    return per_test, shapes

def cmd_summary(args):
    per_test, shapes = read_log(args.log)
    total = sum(sum(c.values()) for c in per_test.values())
    print("total spawns: %d across %d tests" % (total, len(per_test)))
    print("\ntop shapes:")
    for shape, count in shapes.most_common(args.top):
        print("%7d  %s" % (count, shape))
    print("\nmost-spawn tests:")
    ranked = sorted(per_test.items(), key=lambda kv: -sum(kv[1].values()))
    for test, counter in ranked[:args.top]:
        print("%7d  %s" % (sum(counter.values()), test))

def cmd_compare(args):
    base, _ = read_log(args.base)
    head, _ = read_log(args.head)
    if args.completed:
        allowed = None
        for path in args.completed:
            names = set(json.loads(Path(path).read_text()))
            allowed = names if allowed is None else allowed & names
        tests = sorted(allowed)
    else:
        tests = sorted(set(base) & set(head))
    base_total = head_total = 0
    for test in tests:
        b = sum(base.get(test, {}).values())
        h = sum(head.get(test, {}).values())
        base_total += b
        head_total += h
        print("%+6d  %6d -> %6d  %s" % (h - b, b, h, test))
    print("\ncompared %d tests: %d -> %d (%+d)" % (
        len(tests), base_total, head_total, head_total - base_total))

parser = argparse.ArgumentParser(prog="git-spawn-profile-helper.sh")
sub = parser.add_subparsers(dest="command", required=True)
p = sub.add_parser("run")
p.add_argument("worktree")
p.add_argument("out_dir")
p.add_argument("filters", nargs="*")
p.set_defaults(func=cmd_run)
p = sub.add_parser("summary")
p.add_argument("log")
p.add_argument("--top", type=int, default=15)
p.set_defaults(func=cmd_summary)
p = sub.add_parser("compare")
p.add_argument("base")
p.add_argument("head")
p.add_argument("--completed", action="append")
p.set_defaults(func=cmd_compare)
args = parser.parse_args(sys.argv[1:])
args.func(args)
PY
	return $?
}

main "$@"
