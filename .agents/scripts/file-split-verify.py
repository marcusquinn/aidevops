#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Prove that a file-split commit range is a pure move.

Reads `git diff --no-color --no-renames -U0 BASE...HEAD` and runs three checks:

1. Moved-line multiset. Removed and added lines (trailing whitespace stripped)
   are compared as multisets. A removed-only line means logic was deleted or
   edited: FAIL. An added-only line is RESIDUE when it matches the scaffolding
   allowlist below, otherwise REVIEW, which is also a FAIL.
2. Moved-function gate. A shell function definition removed from file A and
   added to file B (A != B) is "moved". `caller_script` is BASH_SOURCE[1] at
   the gh wrapper call, i.e. the file that DEFINES the calling function, so a
   trust gate that pins `caller_function == "<fn>"` together with A's basename
   silently stops matching after the move. Such a function is GATED: FAIL.
   A pin whose nearby script reference is a variable, or absent, fails closed.
3. Stale pointers. Tracked text at HEAD that still says `A::<fn>`, plus
   `EDIT:` lines naming A beside the function name or in a file that holds an
   `A::<fn>` pointer, prints WARN with file:line. Warnings never change the
   exit code.

Residue allowlist (stripped added-only lines): blank; `#` comments (shebang,
SPDX, `# shellcheck`); include-guard lines naming a `*_LOADED`/`*_INCLUDED`/
`*_SOURCED` variable; `source`/`.` lines, including `if ! source ...; then`;
directory resolution for a source (lines using `BASH_SOURCE`, `*_DIR=` /
`SCRIPT_DIR` assignments and tests); `unset` lines; `fi`/`then`/`else`;
`return|exit N 2>/dev/null || exit N` and bare `return|exit N`; and
`printf`/`echo` "failed to load/source" diagnostics sent to stderr.

Output: one summary line, then details. Exit 0 = pure move, 1 = FAIL,
2 = usage or git error. Local git only: no network, no GitHub API.

Merged squash PR: `--base <merge>^ --head <merge>`.
"""

import argparse
import collections
import re
import subprocess
import sys

SHELL_SUFFIXES = (".sh", ".bash", ".zsh")
FUNC_DEF_RES = (
    re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_:.-]*)\s*(?:\(\s*\))?\s*(?:\{.*)?$"),
    re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_:.-]*)\s*\(\s*\)\s*(?:\{.*)?$"),
)
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
RESIDUE_RES = tuple(
    re.compile(pattern)
    for pattern in (
        r"^$",
        r"^#",
        r"\b[A-Za-z0-9_]*_(?:LOADED|INCLUDED|SOURCED)\b",
        r"^(?:if\s+!?\s*)?(?:source|\.)\s+\S",
        r"BASH_SOURCE",
        r"^(?:readonly\s+|local\s+|export\s+)?[A-Za-z0-9_]*(?:_DIR|_dir)=",
        r"\bSCRIPT_DIR\b",
        r"^unset\s",
        r"^(?:fi|then|else)$",
        r"^(?:return|exit)\s+\d+(?:\s+2>\s*/dev/null\s*\|\|\s*exit\s+\d+)?;?$",
        r"^(?:printf|echo)\b.*\b(?:failed to (?:load|source)|cannot (?:load|source))\b.*>&2;?$",
    )
)
PIN_GREP = r'caller_function"?[[:space:]]*=='
SCRIPT_REF_RE = re.compile(r"framework_script\(|caller_script")
SCRIPT_LITERAL_RE = re.compile(r"([A-Za-z0-9_.+-]+\.(?:sh|bash|jq|py))\b")
SCRIPT_VARIABLE_RE = re.compile(
    r'framework_script\(\s*\$|caller_script"?\s*==\s*"?\$'
)
PIN_WINDOW_BEFORE = 3
PIN_WINDOW_AFTER = 4


class GitError(Exception):
    """A git invocation failed."""


def git(*args, ok_codes=(0,)):
    """Run git and return decoded stdout; raise GitError on failure."""
    proc = subprocess.run(
        ["git", "-c", "core.quotePath=false", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode not in ok_codes:
        message = proc.stderr.decode("utf-8", "replace").strip()
        raise GitError(f"git {' '.join(args)}: {message or proc.returncode}")
    return proc.stdout.decode("utf-8", "surrogateescape")


def diff_path(header_line, prefix):
    """Return the path from a `--- a/x` or `+++ b/x` header, or None."""
    value = header_line[4:].rstrip("\t")
    if value == "/dev/null":
        return None
    return value[len(prefix):] if value.startswith(prefix) else value


def parse_diff(text):
    """Return (removed, added) lists of (path, line_no, content)."""
    removed, added = [], []
    old_path = new_path = None
    old_no = new_no = 0
    in_hunk = False
    for line in text.split("\n"):
        if line.startswith("diff --git "):
            old_path = new_path = None
            in_hunk = False
            continue
        if not in_hunk and line.startswith("--- "):
            old_path = diff_path(line, "a/")
            continue
        if not in_hunk and line.startswith("+++ "):
            new_path = diff_path(line, "b/")
            continue
        match = HUNK_RE.match(line)
        if match:
            in_hunk = True
            old_no, new_no = int(match.group(1)), int(match.group(2))
            continue
        if not in_hunk:
            continue
        if line.startswith("-"):
            removed.append((old_path, old_no, line[1:].rstrip()))
            old_no += 1
        elif line.startswith("+"):
            added.append((new_path, new_no, line[1:].rstrip()))
            new_no += 1
    return removed, added


def is_residue(content):
    """Return True when an added-only line is split scaffolding."""
    stripped = content.strip()
    return any(pattern.search(stripped) for pattern in RESIDUE_RES)


def unmatched(entries, surplus):
    """Return entries whose content is in the surplus multiset, in order."""
    remaining = collections.Counter(surplus)
    result = []
    for entry in entries:
        if remaining[entry[2]] > 0:
            remaining[entry[2]] -= 1
            result.append(entry)
    return result


def function_defs(entries):
    """Map shell path -> set of function names defined in the entries."""
    defs = collections.defaultdict(set)
    for path, _line_no, content in entries:
        if not path or not path.endswith(SHELL_SUFFIXES):
            continue
        for pattern in FUNC_DEF_RES:
            match = pattern.match(content)
            if match:
                defs[path].add(match.group(1))
                break
    return defs


def moved_functions(removed, added):
    """Return sorted (fn, old_path, new_path) for cross-file moves."""
    removed_defs, added_defs = function_defs(removed), function_defs(added)
    moves = set()
    for old_path, names in removed_defs.items():
        for name in names - added_defs.get(old_path, set()):
            for new_path, new_names in added_defs.items():
                if new_path != old_path and name in new_names:
                    moves.add((name, old_path, new_path))
    return sorted(moves)


def grep_head(head, args, pathspecs=(".",)):
    """Run git grep at HEAD and return (path, line_no, content) hits."""
    output = git("grep", "-n", "-I", *args, head, "--", *pathspecs, ok_codes=(0, 1))
    prefix = f"{head}:"
    hits = []
    for line in output.splitlines():
        if line.startswith(prefix):
            line = line[len(prefix):]
        match = re.match(r"^(.*?):(\d+):(.*)$", line)
        if match:
            hits.append((match.group(1), int(match.group(2)), match.group(3)))
    return hits


def file_lines(head, path, cache):
    """Return the lines of path at HEAD (cached)."""
    if path not in cache:
        cache[path] = git("show", f"{head}:{path}").split("\n")
    return cache[path]


def basename_re(name):
    """Match a file basename not embedded in a longer file name."""
    return re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(name) + r"(?![A-Za-z0-9_-])")


def pin_is_gate_for(head, path, line_no, old_base, cache):
    """Decide whether a caller_function pin at path:line_no binds old_base."""
    lines = file_lines(head, path, cache)
    start = max(0, line_no - 1 - PIN_WINDOW_BEFORE)
    window = lines[start:line_no + PIN_WINDOW_AFTER]
    literals, variable = set(), False
    for text in window:
        if not SCRIPT_REF_RE.search(text):
            continue
        if SCRIPT_VARIABLE_RE.search(text):
            variable = True
        literals.update(SCRIPT_LITERAL_RE.findall(text))
    if old_base in literals or variable:
        return True
    # No script reference near the pin: fail closed.
    return not literals


def gate_findings(head, moves):
    """Return {(fn, old, new): [(path, line_no, content)]} for gated moves."""
    if not moves:
        return {}
    # Documentation can quote a pin without enforcing it.
    pins = [hit for hit in grep_head(head, ["-E", "-e", PIN_GREP]) if not hit[0].endswith(".md")]
    cache, findings = {}, {}
    for move in moves:
        name, old_path = move[0], move[1]
        old_base = old_path.rsplit("/", 1)[-1]
        pin_re = re.compile(r'caller_function"?\s*==\s*"' + re.escape(name) + r'"')
        sites = []
        for path, line_no, content in pins:
            if pin_re.search(content) and pin_is_gate_for(head, path, line_no, old_base, cache):
                sites.append((path, line_no, content.strip()))
        if sites:
            old_re = basename_re(old_base)
            for path, line_no, content in sites[:]:
                for offset, text in enumerate(file_lines(head, path, cache)[line_no:line_no + PIN_WINDOW_AFTER], 1):
                    if SCRIPT_REF_RE.search(text) and old_re.search(text):
                        sites.append((path, line_no + offset, text.strip()))
            findings[move] = sorted(set(sites))
    return findings


def stale_pointers(head, moves):
    """Return sorted (path, line_no, content, fn, new_path) WARN entries."""
    warnings = {}
    edit_lines = grep_head(head, ["-F", "-e", "EDIT:"]) if moves else []
    for name, old_path, new_path in moves:
        old_base = old_path.rsplit("/", 1)[-1]
        old_re = basename_re(old_base)
        pointer_re = re.compile(
            r"(?<![A-Za-z0-9_.-])" + re.escape(f"{old_base}::{name}") + r"(?![A-Za-z0-9_])"
        )
        pointer_files = set()
        for path, line_no, content in grep_head(head, ["-F", "-e", f"{old_base}::{name}"]):
            if pointer_re.search(content):
                pointer_files.add(path)
                warnings[(path, line_no)] = (content.strip(), name, new_path)
        for path, line_no, content in edit_lines:
            if not old_re.search(content) or (path, line_no) in warnings:
                continue
            if path in pointer_files or re.search(r"\b" + re.escape(name) + r"\b", content):
                warnings[(path, line_no)] = (content.strip(), name, new_path)
    return sorted((path, line_no, *rest) for (path, line_no), rest in warnings.items())


def location(entry):
    """Format a (path, line_no, content) entry."""
    path, line_no, content = entry
    return f"{path or '/dev/null'}:{line_no}: {content}"


def main(argv=None):
    """Run the verifier; return the process exit code."""
    parser = argparse.ArgumentParser(
        description="Verify that a file-split commit range is a pure move.",
        epilog="Exit 0 = pure move, 1 = FAIL, 2 = usage or git error.",
    )
    parser.add_argument("--base", default="origin/main", help="base ref (default origin/main)")
    parser.add_argument("--head", default="HEAD", help="head ref (default HEAD)")
    parser.add_argument("--max-details", type=int, default=50, metavar="N",
                        help="detail lines per section (default 50; 0 = all)")
    args = parser.parse_args(argv)
    if args.max_details < 0:
        parser.error("--max-details must be >= 0")

    try:
        git("rev-parse", "--verify", f"{args.base}^{{commit}}")
        head = git("rev-parse", "--verify", f"{args.head}^{{commit}}").strip()
        diff = git("diff", "--no-color", "--no-renames", "--no-ext-diff", "-U0",
                   f"{args.base}...{head}")
        removed, added = parse_diff(diff)
        removed_counter = collections.Counter(entry[2] for entry in removed)
        added_counter = collections.Counter(entry[2] for entry in added)
        removed_only = unmatched(removed, removed_counter - added_counter)
        added_only = unmatched(added, added_counter - removed_counter)
        review = [entry for entry in added_only if not is_residue(entry[2])]
        residue = len(added_only) - len(review)
        moves = moved_functions(removed, added)
        gated = gate_findings(head, moves)
        warnings = stale_pointers(head, moves)
    except GitError as error:
        print(f"file-split-verify: {error}", file=sys.stderr)
        return 2

    failed = bool(removed_only or review or gated)
    print(
        f"removed={len(removed)} added={len(added)} removed-only={len(removed_only)} "
        f"review={len(review)} gated={len(gated)} warn={len(warnings)} "
        f"residue={residue} moved-functions={len(moves)} "
        f"result={'FAIL' if failed else 'PASS'}"
    )

    def emit(label, entries):
        limit = args.max_details or len(entries)
        for entry in entries[:limit]:
            print(f"{label} {entry}")
        if len(entries) > limit:
            print(f"{label} ... {len(entries) - limit} more (use --max-details 0)")

    emit("REMOVED-ONLY", [location(entry) for entry in removed_only])
    emit("REVIEW", [location(entry) for entry in review])
    for (name, old_path, new_path), sites in gated.items():
        print(f"GATED {name}: moved {old_path} -> {new_path}; file-identity gate pins it at:")
        for site in sites:
            print(f"GATED   {location(site)}")
    emit("WARN", [
        f"{path}:{line_no}: stale pointer for {name} (now in {new_path}): {content}"
        for path, line_no, content, name, new_path in warnings
    ])
    emit("MOVED", [f"{name}: {old_path} -> {new_path}" for name, old_path, new_path in moves])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
