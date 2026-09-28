#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify surviving repository-wide batch quality invariants.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass_count=0
fail_count=0

check() {
	local description="$1"
	shift
	if "$@"; then
		printf 'PASS %s\n' "$description"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL %s\n' "$description"
		fail_count=$((fail_count + 1))
	fi
	return 0
}

json_configs_valid() {
	local file=""
	while IFS= read -r file; do
		python3 -m json.tool "$REPO_DIR/$file" >/dev/null || return 1
	done < <(git -C "$REPO_DIR" ls-files 'configs/*.json' 'configs/*.json.txt' 'configs/**/*.json' 'configs/**/*.json.txt')
	return 0
}

shell_scripts_have_shebangs() {
	local file=""
	local first_line=""
	while IFS= read -r file; do
		IFS= read -r first_line <"$REPO_DIR/$file" || true
		[[ "$first_line" == '#!'* ]] || return 1
	done < <(git -C "$REPO_DIR" ls-files '*.sh')
	return 0
}

gitignore_has_artifacts() {
	[[ -z "$(git -C "$REPO_DIR" ls-files .scannerwork .playwright-cli)" ]] || return 1
	grep -q 'scannerwork' "$REPO_DIR/.gitignore" || return 1
	grep -q 'playwright-cli' "$REPO_DIR/.gitignore" || return 1
	return 0
}

package_metadata_valid() {
	python3 - "$REPO_DIR/package.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as config:
    data = json.load(config)
assert "bin" in data
assert "main" not in data or os.path.isfile(os.path.join(os.path.dirname(path), data["main"]))
PY
	return $?
}

check 'Tracked JSON configs parse' json_configs_valid
check 'Corrupted pandoc keys are absent' python3 -c "import json; d=json.load(open('$REPO_DIR/configs/pandoc-config.json.txt')); assert all('\\n' not in key for key in d)"
check 'Gitignored artifacts stay untracked' gitignore_has_artifacts
check 'Package metadata resolves' package_metadata_valid
check 'Tracked shell scripts have shebangs' shell_scripts_have_shebangs
check 'Setup parses' bash -n "$REPO_DIR/setup.sh"
check 'CLI parses' bash -n "$REPO_DIR/aidevops.sh"

printf 'Results: %d passed, %d failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
