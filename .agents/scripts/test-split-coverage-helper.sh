#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Compare static case-invocation multisets without executing any suite code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

python3 - "$@" <<'PY'
import argparse
from collections import Counter
from pathlib import Path
import re
import subprocess
import sys


def paths(value):
    entries = value.split(",")
    if any(not entry.strip() for entry in entries):
        raise argparse.ArgumentTypeError("paths must be non-empty comma-separated names")
    return [entry.strip() for entry in entries]


parser = argparse.ArgumentParser(
    description="Prove a root suite split preserves bare test_/run_ invocations. "
                "Only run_ functions in explicitly listed modules are expanded; "
                "this is not a general shell parser and never executes suite code.")
parser.add_argument("command", choices=("check",))
parser.add_argument("--original", required=True, metavar="REF:ROOT-PATH")
parser.add_argument("--roots", required=True, type=paths, metavar="ROOT1,ROOT2,...")
parser.add_argument("--modules", default=[], type=paths, metavar="MODULE1,MODULE2,...")
args = parser.parse_args()
ref, separator, original_path = args.original.partition(":")
if not separator or not ref or not original_path:
    parser.error("--original must be REF:ROOT-PATH")

# Match the deliberately narrow invocation contract, not commands in strings,
# comments, conditionals or calls with arguments. Functions end at a closing
# brace at the same indentation as their declaration (nested braces are ignored).
declaration = re.compile(r"^(\s*)(?:function\s+)?(\w+)\s*\(\s*\)\s*\{\s*(?:#.*)?$")
invocation = re.compile(r"^\s+((?:test_|run_)\w+)$")


def functions(text):
    result = {}
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = declaration.fullmatch(line)
        if not match:
            continue
        indent, name = match.groups()
        if name != "main" and not name.startswith("run_"):
            continue
        end = index + 1
        while end < len(lines) and lines[end].rstrip() != indent + "}":
            end += 1
        if end == len(lines):
            raise ValueError("unterminated function: " + name)
        if name in result:
            raise ValueError("ambiguous function definition: " + name)
        result[name] = [m.group(1) for body_line in lines[index + 1:end]
                        if (m := invocation.fullmatch(body_line.rstrip()))]
    return result


def read(path, historical=False):
    if historical:
        completed = subprocess.run(
            ["git", "show", f"{ref}:{path}"], check=True,
            capture_output=True, text=True)
        return completed.stdout
    return Path(path).read_text(encoding="utf-8")


def groups(historical):
    result = {}
    for path in args.modules:
        for name, calls in functions(read(path, historical)).items():
            if not name.startswith("run_"):
                continue
            if name in result:
                raise ValueError("group defined in multiple modules: " + name)
            result[name] = calls
    return result


def cases(root_paths, historical=False):
    definitions = groups(historical)

    def expand(name, stack=()):
        if name not in definitions:
            return [name]
        if name in stack:
            raise ValueError("recursive group: " + " -> ".join(stack + (name,)))
        if not definitions[name]:
            raise ValueError("group has no bare invocations: " + name)
        return [case for child in definitions[name]
                for case in expand(child, stack + (name,))]

    result = Counter()
    for path in root_paths:
        main = functions(read(path, historical)).get("main")
        if not main:
            raise ValueError("missing main() or no bare invocations: " + path)
        for name in main:
            result.update(expand(name))
    return result


try:
    original = cases([original_path], historical=True)
    split = cases(args.roots)
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    print(f"error: {error}", file=sys.stderr)
    sys.exit(1)

missing = sorted((original - split).elements())
extra = sorted((split - original).elements())
duplicated = sorted(name for name, count in split.items() if count > 1)
print(f"original cases: {sum(original.values())} split cases: {sum(split.values())}")
print(f"missing: {missing}")
print(f"extra: {extra}")
print(f"duplicated: {duplicated}")
sys.exit(1 if missing or extra or duplicated else 0)
PY
