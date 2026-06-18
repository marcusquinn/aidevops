#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

load_function() {
	python3 - "$REPO_DIR/aidevops.sh" <<'PY'
import sys

path = sys.argv[1]
collect = False
depth = 0
with open(path, "r", encoding="utf-8") as handle:
    for line in handle:
        if line.startswith("ensure_trailing_newline()"):
            collect = True
        if collect:
            print(line, end="")
            depth += line.count("{") - line.count("}")
            if depth == 0 and line.strip() == "}":
                break
PY
	return 0
}

eval "$(load_function)"

assert_file_bytes() {
	local file="$1"
	local expected="$2"
	local actual
	actual="$(python3 - "$file" <<'PY'
import sys
with open(sys.argv[1], "rb") as handle:
    print(repr(handle.read().decode("utf-8")))
PY
)"
	if [[ "$actual" != "$expected" ]]; then
		printf 'Expected %s, got %s\n' "$expected" "$actual" >&2
		return 1
	fi
	return 0
}

with_newline="$TMP_DIR/with-newline.txt"
without_newline="$TMP_DIR/without-newline.txt"
empty_file="$TMP_DIR/empty.txt"

printf 'already newline\n' >"$with_newline"
printf 'missing newline' >"$without_newline"
: >"$empty_file"

ensure_trailing_newline "$with_newline"
ensure_trailing_newline "$without_newline"
ensure_trailing_newline "$empty_file"

assert_file_bytes "$with_newline" "'already newline\\n'"
assert_file_bytes "$without_newline" "'missing newline\\n'"
assert_file_bytes "$empty_file" "''"

printf 'ensure_trailing_newline handles newline-present, newline-missing, and empty files\n'
