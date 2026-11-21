#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Paired base/head subprocess spawn profiler.

run      run a suite on base and head with PATH-prepended logging wrappers
summary  report spawn counts, top signatures and same-process exact repeats
compare  per-signature delta table between two logs

Log format (TSV, one spawn per line; header line `#root<TAB><tree>`):
start<TAB>end<TAB>pid<TAB>ppid<TAB>cwd<TAB>argv. Wrappers exec the real tool, so
`end` is `-`. Environment values and file contents are never logged.
"""
import argparse
import os
import re
import shutil
import subprocess  # nosec B404
import sys
import tempfile
import time
from collections import Counter, defaultdict
from pathlib import Path

WRAPPER = """#!@BASH@
# spawn-profile wrapper: log one line, then exec the next tool on PATH unchanged.
tool="${0##*/}"
real=""
IFS=: read -r -a dirs <<<"$PATH"
for d in "${dirs[@]}"; do
	[[ "$d" == "$SPAWN_PROFILE_DIR" ]] && continue
	if [[ -x "$d/$tool" && ! -d "$d/$tool" ]]; then real="$d/$tool"; break; fi
done
if [[ -n "$SPAWN_PROFILE_LOG" ]]; then
	argv="$tool $*"
	argv="${argv//$'\\t'/ }"
	argv="${argv//$'\\n'/ }"
	printf '%s\\t-\\t%s\\t%s\\t%s\\t%s\\n' "${EPOCHREALTIME:-0}" "$$" "$PPID" "$PWD" "${argv:0:600}" \\
		>>"$SPAWN_PROFILE_LOG" 2>/dev/null || true
fi
[[ -n "$real" ]] || { echo "spawn-profile: $tool not found" >&2; exit 127; }
exec "$real" "$@"
"""

OID_RE = re.compile(r"\b(?:[0-9a-f]{64}|[0-9a-f]{40})\b")
PATH_RE = re.compile(r"(?<![\w.-])/[^\s'\"=:]+")


def tmp_root():
    configured = os.environ.get("AIDEVOPS_TEMP_DIR")
    return Path(configured) if configured else Path.home() / ".aidevops/.agent-workspace/tmp"


def normalise(argv):
    argv = OID_RE.sub("<OID>", argv)
    return PATH_RE.sub("<P>", argv)


def read_log(path):
    root, rows = "", []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t", 5)
            if parts[0] == "#root" and len(parts) > 1:
                root = parts[1]
            elif len(parts) == 6 and not parts[0].startswith("#"):
                rows.append(parts)
    return root, rows


def is_code_under_test(cwd, root):
    return bool(root) and (cwd == root or cwd.startswith(root.rstrip("/") + "/"))


def stats(path):
    root, rows = read_log(path)
    sigs, repeats, parents = Counter(), Counter(), defaultdict(Counter)
    seen, starts, fixture = Counter(), [], 0
    for start, _end, _pid, ppid, cwd, argv in rows:
        sig = normalise(argv)
        sigs[sig] += 1
        parents[sig][ppid] += 1
        seen[(ppid, argv)] += 1
        if not is_code_under_test(cwd, root):
            fixture += 1
        try:
            starts.append(float(start))
        except ValueError:
            pass
    for (_ppid, argv), n in seen.items():
        if n > 1:
            repeats[normalise(argv)] += n - 1
    span = (max(starts) - min(starts)) if len(starts) > 1 else 0.0
    return {"total": len(rows), "sigs": sigs, "repeats": repeats, "parents": parents,
            "fixture": fixture, "span": span}


def cmd_summary(args):
    s = stats(args.log)
    print("spawns: %d  span_seconds: %.1f  fixture: %d  code_under_test: %d  same_process_repeats: %d"
          % (s["total"], s["span"], s["fixture"], s["total"] - s["fixture"], sum(s["repeats"].values())))
    print("\n| spawns | repeats | parents | signature |\n|---:|---:|---:|---|")
    for sig, n in s["sigs"].most_common(args.top):
        print("| %d | %d | %d | `%s` |" % (n, s["repeats"].get(sig, 0), len(s["parents"][sig]), sig))
    return 0


def cmd_compare(args):
    base, head = stats(args.base_log), stats(args.head_log)
    print("total spawns: %d -> %d (%+d)" % (base["total"], head["total"], head["total"] - base["total"]))
    keys = set(base["sigs"]) | set(head["sigs"])
    rows = sorted(((head["sigs"][k] - base["sigs"][k], k) for k in keys if head["sigs"][k] != base["sigs"][k]),
                  key=lambda r: (-abs(r[0]), r[1]))
    print("\n| base | head | delta | signature |\n|---:|---:|---:|---|")
    for delta, sig in rows[: args.top]:
        print("| %d | %d | %+d | `%s` |" % (base["sigs"][sig], head["sigs"][sig], delta, sig))
    if not rows:
        print("| 0 | 0 | 0 | (no per-signature differences) |")
    return 0


def run_suite(tree, rel_cwd, command, tools, log, wrap_dir):
    wrap_dir.mkdir(parents=True)
    # Absolute interpreter, resolved before PATH changes: a `bash` wrapper must not re-enter itself.
    script = WRAPPER.replace("@BASH@", shutil.which("bash") or "/bin/bash")
    for tool in tools:
        wrapper = wrap_dir / tool
        wrapper.write_text(script)
        wrapper.chmod(0o755)
    log.write_text("#root\t%s\n" % tree)
    env = dict(os.environ, SPAWN_PROFILE_LOG=str(log), SPAWN_PROFILE_DIR=str(wrap_dir),
               PATH=str(wrap_dir) + os.pathsep + os.environ.get("PATH", ""))
    # Caller-supplied argv; no shell.
    return subprocess.run(command, cwd=str(tree / rel_cwd), env=env).returncode  # nosec B603


def git_out(*cmd):
    return subprocess.run(["git", *cmd], check=True, text=True,  # nosec B603 B607
                          stdout=subprocess.PIPE).stdout.strip()


def cmd_run(args):
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        sys.exit("error: suite command required after --")
    tools = [t for t in args.tool.split(",") if t]
    for tool in tools:
        if not re.fullmatch(r"[A-Za-z0-9._+-]+", tool):
            sys.exit("error: invalid tool name: %s" % tool)
    top = Path(git_out("rev-parse", "--show-toplevel"))
    rel = Path(os.path.relpath(Path.cwd(), top))
    root = tmp_root()
    root.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="spawn-profile-", dir=str(root)))
    base_tree = out / "base-tree"
    wrap_dirs = [out / "wrap-base", out / "wrap-head"]
    try:
        subprocess.run(["git", "worktree", "add", "--detach", str(base_tree), args.base],  # nosec B603 B607
                       check=True, stdout=subprocess.DEVNULL)
        t0 = time.monotonic()
        base_rc = run_suite(base_tree, rel, command, tools, out / "base.tsv", wrap_dirs[0])
        head_rc = run_suite(top, rel, command, tools, out / "head.tsv", wrap_dirs[1])
        print("suite exit status: base=%d head=%d (%.1fs)" % (base_rc, head_rc, time.monotonic() - t0))
    finally:
        for wrap in wrap_dirs:
            shutil.rmtree(wrap, ignore_errors=True)
        if base_tree.exists():
            subprocess.run(["git", "worktree", "remove", "--force", str(base_tree)],  # nosec B603 B607
                           check=False)
    print("logs: %s/base.tsv %s/head.tsv\n" % (out, out))
    print("## base\n")
    cmd_summary(argparse.Namespace(log=str(out / "base.tsv"), top=args.top))
    print("\n## head\n")
    cmd_summary(argparse.Namespace(log=str(out / "head.tsv"), top=args.top))
    print("\n## delta (base -> head)\n")
    cmd_compare(argparse.Namespace(base_log=str(out / "base.tsv"), head_log=str(out / "head.tsv"),
                                   top=args.top))
    return head_rc


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run")
    run.add_argument("--base", required=True)
    run.add_argument("--tool", default="git")
    run.add_argument("--top", type=int, default=20)
    run.add_argument("command", nargs=argparse.REMAINDER)
    summary = sub.add_parser("summary")
    summary.add_argument("log")
    summary.add_argument("--top", type=int, default=20)
    compare = sub.add_parser("compare")
    compare.add_argument("base_log")
    compare.add_argument("head_log")
    compare.add_argument("--top", type=int, default=30)
    args = parser.parse_args()
    return {"run": cmd_run, "summary": cmd_summary, "compare": cmd_compare}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
