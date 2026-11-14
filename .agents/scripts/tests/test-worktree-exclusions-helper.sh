#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../worktree-exclusions-helper.sh disable=SC1091
source "$SCRIPT_DIR/../worktree-exclusions-helper.sh"

_we_is_macos() { return 0; }
_we_has_backblaze() { return 0; }
# BSD grep does not support -P; reject it even on GNU hosts.
grep() {
	local arg=""
	for arg in "$@"; do
		if [[ "$arg" == -*P* ]]; then return 2; fi
	done
	command grep "$@" || return 1
	return 0
}

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export AIDEVOPS_BACKBLAZE_BZINFO="$test_dir/bzinfo.xml"

printf '<config use_time_machine_excludes="true" />\n' > "$AIDEVOPS_BACKBLAZE_BZINFO"
output=$(cmd_setup_backblaze)
[[ "$output" == *"already covered"* && "$output" != *"not currently set"* ]]

printf '<config use_time_machine_excludes="false" />\n' > "$AIDEVOPS_BACKBLAZE_BZINFO"
output=$(cmd_setup_backblaze)
[[ "$output" == *"not currently set"* && "$output" == *"Use Time Machine excludes"* ]]
printf 'Backblaze inheritance checks passed\n'
