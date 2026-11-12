#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Prove that a file-split commit range is a pure move.

Reads `git diff --no-color --no-renames -U0 BASE...HEAD` and runs three checks:

1. Moved-line multiset. Removed and added lines (trailing whitespace stripped)
   are compared as multisets. A removed-only line means logic was deleted or
   edited: FAIL. An added-only line is RESIDUE when it matches the scaffolding
   allowlist below, otherwise REVIEW, which is also a FAIL.
   Binary changes (`Binary files differ`) cannot be line-verified: FAIL.
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

Implementation lives in sibling `_file_split_*.py` modules (git, diff, residue,
moves, gate); this file is the CLI entry point.
"""

import argparse
import collections
import sys

from _file_split_diff import binary_changes, mode_changes, parse_diff, unmatched
from _file_split_gate import gate_findings, stale_pointers
from _file_split_git import GitError, git
from _file_split_moves import moved_functions
from _file_split_residue import is_residue

BLOCKING_KEYS = ("removed_only", "review", "gated", "binary", "modes")


def location(entry):
    """Format a (path, line_no, content) entry."""
    path, line_no, content = entry
    return f"{path or '/dev/null'}:{line_no}: {content}"


def parse_args(argv):
    """Parse and validate command-line arguments."""
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
    if args.base.startswith("-") or args.head.startswith("-"):
        parser.error("--base and --head must be refs, not options")
    return args


def analyse(args):
    """Run all checks and return a dict of findings; raise GitError on failure."""
    base = git("rev-parse", "--verify", "--end-of-options", f"{args.base}^{{commit}}").strip()
    head = git("rev-parse", "--verify", "--end-of-options", f"{args.head}^{{commit}}").strip()
    diff = git("diff", "--no-color", "--no-renames", "--no-ext-diff", "--no-textconv",
               "-U0", f"{base}...{head}", "--")
    removed, added = parse_diff(diff)
    removed_counter = collections.Counter(entry[2] for entry in removed)
    added_counter = collections.Counter(entry[2] for entry in added)
    added_only = unmatched(added, added_counter - removed_counter)
    review = [entry for entry in added_only if not is_residue(entry[2])]
    moves = moved_functions(removed, added)
    return {
        "removed": removed,
        "added": added,
        "removed_only": unmatched(removed, removed_counter - added_counter),
        "review": review,
        "residue": len(added_only) - len(review),
        "binary": binary_changes(diff),
        "modes": mode_changes(diff),
        "moves": moves,
        "gated": gate_findings(head, moves),
        "warnings": stale_pointers(head, moves),
    }


def has_failure(result):
    """Return True when any blocking finding is present."""
    return any(result[key] for key in BLOCKING_KEYS)


def summary_line(result, failed):
    """Format the one-line summary."""
    return (
        f"removed={len(result['removed'])} added={len(result['added'])} "
        f"removed-only={len(result['removed_only'])} review={len(result['review'])} "
        f"binary={len(result['binary'])} mode={len(result['modes'])} "
        f"gated={len(result['gated'])} warn={len(result['warnings'])} "
        f"residue={result['residue']} moved-functions={len(result['moves'])} "
        f"result={'FAIL' if failed else 'PASS'}"
    )


def emit(label, entries, max_details):
    """Print up to max_details lines (0 = all) for one section."""
    limit = max_details or len(entries)
    for entry in entries[:limit]:
        print(f"{label} {entry}")
    if len(entries) > limit:
        print(f"{label} ... {len(entries) - limit} more (use --max-details 0)")


def emit_gated(gated):
    """Print gated moves with the pin sites that bind the old file."""
    for (name, old_path, new_path), sites in gated.items():
        print(f"GATED {name}: moved {old_path} -> {new_path}; file-identity gate pins it at:")
        for site in sites:
            print(f"GATED   {location(site)}")


def report(result, max_details):
    """Print detail sections after the summary line."""
    emit("REMOVED-ONLY", [location(entry) for entry in result["removed_only"]], max_details)
    emit("REVIEW", [location(entry) for entry in result["review"]], max_details)
    emit("BINARY", result["binary"], max_details)
    emit("MODE", result["modes"], max_details)
    emit_gated(result["gated"])
    emit("WARN", [
        f"{path}:{line_no}: stale pointer for {name} (now in {new_path}): {content}"
        for path, line_no, content, name, new_path in result["warnings"]
    ], max_details)
    emit("MOVED", [f"{name}: {old} -> {new}" for name, old, new in result["moves"]], max_details)


def main(argv=None):
    """Run the verifier; return the process exit code."""
    args = parse_args(argv)
    try:
        result = analyse(args)
    except GitError as error:
        print(f"file-split-verify: {error}", file=sys.stderr)
        return 2
    failed = has_failure(result)
    print(summary_line(result, failed))
    report(result, args.max_details)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
