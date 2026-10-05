#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Opt-in repository migration; Python provides portable, non-octal integers.
set -euo pipefail

main() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'task-id-normalize: python3 is required\n' >&2
		return 1
	fi
	python3 - "$@" <<'PY'
import argparse
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description="Normalize padded legacy task IDs (dry-run by default)")
mode = parser.add_mutually_exclusive_group()
boolean_action = "store_true"
brief_suffix = "-brief.md"
mode.add_argument("--apply", action=boolean_action)
mode.add_argument("--dry-run", action=boolean_action)
mode.add_argument("--advisory", action=boolean_action, help="Only advise when TODO.md has padded IDs")
parser.add_argument("--repo", default=".", help="Repository root (default: current Git worktree)")
args = parser.parse_args()
root = Path(subprocess.check_output(["git", "-C", args.repo, "rev-parse", "--show-toplevel"], text=True).strip())
# Whole tokens only: exclude branch names, URLs, namespaced IDs and malformed suffixes.
token = re.compile(r"(?<![\w./-])t[0-9]+(?:\.[0-9]+)*(?![\w.-])")
brief_ref = re.compile(r"(?<![\w/])todo/tasks/(t[0-9]+(?:\.[0-9]+)*)-brief\.md\b")
canonical = re.compile(r"t[1-9][0-9]{0,17}(?:\.[1-9][0-9]{0,17}){0,8}\Z")
task_line = re.compile(r"^\s*-\s+\[[ x>\-]\]\s+t[0-9]")

def unpad(value):
    if not re.fullmatch(r"t0+[0-9]+(?:\.[0-9]+)*", value):
        return value
    result = "t" + ".".join(part.lstrip("0") or "0" for part in value[1:].split("."))
    return result if canonical.fullmatch(result) else value

def active_lines(text, plans=False):
    toon = False
    paired_toon = False
    archived = False
    archive_level = 0
    for line in text.splitlines(keepends=True):
        heading = re.match(r"^(#{1,6})\s+(.+)", line)
        if heading:
            level = len(heading[1])
            if archived and level <= archive_level:
                archived = False
            if re.search(r"\barchiv(?:e|ed|es)\b", heading[2], re.I):
                archived, archive_level = True, level
        if "<!--TOON:" in line:
            toon = True
            paired_toon = bool(re.search(r"<!--TOON:[\w-]+-->", line))
        yield line, not archived and (plans or toon or bool(task_line.match(line)))
        if "<!--/TOON:" in line or ("-->" in line and not paired_toon):
            toon = False
            paired_toon = False

def ids(line):
    return [m[0] for m in token.finditer(line)] + [m[1] for m in brief_ref.finditer(line)]

todo = root / "TODO.md"
if args.advisory:
    if todo.is_file() and not todo.is_symlink():
        if any(unpad(value) != value for line, active in active_lines(todo.read_text()) if active for value in ids(line)):
            print("warning: TODO.md contains padded legacy IDs; dry-run: bash ~/.aidevops/agents/scripts/task-id-normalize-helper.sh --repo " + repr(str(root)) + " --dry-run")
    sys.exit(0)

originals = {}
rewrites = {}
seen = set()
for relative in ("TODO.md", "todo/PLANS.md"):
    path = root / relative
    if path.is_symlink() or path.parent.is_symlink():
        sys.exit("Refusing symlink: " + relative)
    if not path.is_file():
        continue
    text = path.read_bytes().decode("utf-8")
    originals[path] = text
    output = []
    for line, active in active_lines(text, relative == "todo/PLANS.md"):
        if active:
            seen.update(ids(line))
            new = token.sub(lambda m: unpad(m[0]), line)
            new = brief_ref.sub(lambda m: "todo/tasks/" + unpad(m[1]) + brief_suffix, new)
            if new != line:
                print(relative + ": " + line.rstrip() + " -> " + new.rstrip())
            line = new
        output.append(line)
    rewrites[path] = "".join(output)

renames = []
brief_dir = root / "todo/tasks"
if brief_dir.is_symlink():
    sys.exit("Refusing symlink: todo/tasks")
for path in sorted(brief_dir.glob("t*-brief.md")):
    value = path.name[:-len(brief_suffix)]
    if not re.fullmatch(r"t[0-9]+(?:\.[0-9]+)*", value):
        continue
    seen.add(value)
    replacement = unpad(value)
    if replacement != value:
        target = path.with_name(replacement + brief_suffix)
        renames.append((path, target))
        print("git mv " + str(path.relative_to(root)) + " " + str(target.relative_to(root)))

conflicts = []
destinations = {}
for value in sorted(seen):
    replacement = unpad(value)
    if replacement != value:
        if replacement in seen:
            conflicts.append(value + " and " + replacement + " both exist")
        if replacement in destinations:
            conflicts.append(value + " and " + destinations[replacement] + " normalize to " + replacement)
        destinations[replacement] = value
for source, target in renames:
    if source.is_symlink() or target.exists() or target.is_symlink():
        conflicts.append("unsafe rename: " + str(source.relative_to(root)))
    tracked = subprocess.run(["git", "-C", str(root), "ls-files", "--error-unmatch", "--", str(source.relative_to(root))], capture_output=True)
    if tracked.returncode:
        conflicts.append("brief must be Git-tracked for git mv: " + str(source.relative_to(root)))
if conflicts:
    for conflict in conflicts:
        print("CONFLICT: " + conflict, file=sys.stderr)
    sys.exit(1)

def seed(text):
    # Same decimal high-water semantics as _compute_counter_seed, including padded input.
    return max([0] + [int(m[0][1:].split(".")[0]) for m in token.finditer(text)]) + 1

counter = root / ".task-counter"
counter_before = counter.read_bytes() if counter.exists() else None
before = seed(originals.get(todo, ""))
after = seed(rewrites.get(todo, ""))
if after < before:
    sys.exit("Refusing migration: counter seed would decrease")
if args.apply:
    # Validate the whole run before the first write. Git history and archives are never inputs.
    for source, target in renames:
        subprocess.run(["git", "-C", str(root), "mv", "--", str(source.relative_to(root)), str(target.relative_to(root))], check=True)
    for path, text in rewrites.items():
        if text != originals[path]:
            path.write_bytes(text.encode("utf-8"))
    actual_seed = seed(todo.read_text()) if todo.exists() else 1
    counter_after = counter.read_bytes() if counter.exists() else None
    if actual_seed < before or counter_after != counter_before:
        sys.exit("Post-apply counter invariant failed")
    print(f"Applied; counter seed {before} -> {actual_seed}; .task-counter unchanged")
else:
    print(f"Dry-run only; counter seed {before} -> {after}; rerun with --apply to write")
PY
	return 0
}

main "$@"
