#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#40582: run with MKDIR_RACE_ITERATIONS=2000 on ubuntu:26.04 for reproduction.
set -euo pipefail
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
ITERATIONS="${MKDIR_RACE_ITERATIONS:-200}"

race() {
	local label="$1"
	local native="${2:-0}"
	local index=0 first=0 second=0 pid1='' pid2='' doubles=0
	for ((index = 0; index < ITERATIONS; index++)); do
		if [[ "$native" == 1 ]]; then
			command mkdir "$TEST_ROOT/lock-$index" 2>/dev/null &
			pid1=$!
			command mkdir "$TEST_ROOT/lock-$index" 2>/dev/null &
			pid2=$!
		else
			mkdir "$TEST_ROOT/lock-$index" 2>/dev/null &
			pid1=$!
			mkdir "$TEST_ROOT/lock-$index" 2>/dev/null &
			pid2=$!
		fi
		first=0 second=0
		wait "$pid1" || first=$?
		wait "$pid2" || second=$?
		if [[ "$first" == 0 && "$second" == 0 ]]; then doubles=$((doubles + 1)); fi
		# A broken implementation that rejects every acquisition must also fail.
		[[ "$first" == 0 || "$second" == 0 ]] || return 1
		rmdir "$TEST_ROOT/lock-$index"
	done
	printf '%s: %s double successes / %s iterations\n' "$label" "$doubles" "$ITERATIONS"
	[[ "$native" == 1 || "$doubles" == 0 ]] || return 1
	return 0
}

(
	# shellcheck source=../mkdir-exclusive.sh
	source "$TEST_SCRIPT_DIR/../mkdir-exclusive.sh"
	if [[ "$(command mkdir --version 2>/dev/null || true)" != *uutils* ]]; then
		[[ "$(type -t mkdir)" != function ]]
	fi
	race native-selected-shim
)
race plain-mkdir-negative-control 1

# Exercise the GNU branch when installed. Mock only detection/lookup, never
# the exclusive-create syscall or the contending processes.
(
	command -v gnumkdir >/dev/null 2>&1 || exit 0
	command() {
		if [[ "$*" == 'mkdir --version' ]]; then
			printf 'mkdir (uutils coreutils) fixture\n'
			return 0
		fi
		builtin command "$@"
		return $?
	}
	source "$TEST_SCRIPT_DIR/../mkdir-exclusive.sh"
	[[ "$(type -t mkdir)" == function ]]
	race gnumkdir-selected
	PATH="$TEST_ROOT" mkdir "$TEST_ROOT/pinned-path"
	[[ -d "$TEST_ROOT/pinned-path" ]]
)
(
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'SKIP: Python fallback (python3 unavailable)\n'
		exit 0
	fi
	command() {
		if [[ "$*" == 'mkdir --version' ]]; then
			printf 'mkdir (uutils coreutils) fixture\n'
			return 0
		fi
		if [[ "$*" == '-v gnumkdir' ]]; then return 1; fi
		builtin command "$@"
		return $?
	}
	source "$TEST_SCRIPT_DIR/../mkdir-exclusive.sh"
	[[ "$(type -t mkdir)" == function ]]
	race python-fallback
	mkdir -p "$TEST_ROOT/parents/child"
	mkdir -- "$TEST_ROOT/space and dash-"
	if mkdir -- "$TEST_ROOT/space and dash-" 2>/dev/null; then exit 1; fi
	mkdir -m 700 "$TEST_ROOT/private"
	python3 -c 'import os, stat, sys; assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o700' "$TEST_ROOT/private"
	if mkdir -m 2770 "$TEST_ROOT/special" 2>/dev/null; then exit 1; fi
	[[ ! -e "$TEST_ROOT/special" ]]
	# No -p substring/operand may accidentally delegate an exclusive operation.
	mkdir -- "$TEST_ROOT/--parents"
	if mkdir -- "$TEST_ROOT/--parents" 2>/dev/null; then exit 1; fi
)
printf 'PASS: mkdir compatibility and concurrent exclusivity\n'
