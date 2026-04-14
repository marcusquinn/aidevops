#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#18830 regression test — bash 3.2 NUL-delimited parameter expansion
# crash in pulse-dep-graph.sh.
#
# Root cause: before this fix, `_blocked_by_extract_refs` returned two
# values via `printf '%s\0%s'` and the caller split with `${refs%%$'\0'*}`
# and `${refs#*$'\0'}`. Bash 3.2 has a parser bug where `$'\0'` inside
# a `${...}` parameter expansion triggers
#
#   /bin/bash: bad substitution: no closing `}' in "${refs%%
#
# This aborted the shell, writing the error to stderr (never to LOGFILE),
# silently killing every dispatch candidate that reached
# `is_blocked_by_unresolved`. On macOS default `/bin/bash` (3.2.57), this
# broke pulse's deterministic fill floor for weeks. Contained only by the
# subshell wrapper in `_dff_process_candidate` (PR #18826).
#
# This test locks in three invariants:
#
#   1. The exact broken pattern `"${refs%%$'\0'*}"` MUST crash bash 3.2
#      (so if anyone tries to "optimize" back to NUL delimiters, this test
#      reminds them why we can't have nice things).
#   2. The new split helpers `_blocked_by_extract_tids/nums` return correct
#      values for every supported body format — no NUL involved.
#   3. The source file must NOT contain the broken `$'\0'` pattern inside
#      any `${...}` expansion anywhere in `.agents/scripts/` (a literal
#      grep regression guard so the bug cannot be reintroduced anywhere,
#      not just in pulse-dep-graph.sh).
#
# Usage: bash test-pulse-dep-graph-bash32-nul-crash.sh
# Environment: must be runnable under /bin/bash 3.2 (macOS default).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEP_GRAPH="$REPO_ROOT/.agents/scripts/pulse-dep-graph.sh"

pass_count=0
fail_count=0

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  expected=%q\n  actual=  %q\n' "$label" "$expected" "$actual" >&2
		fail_count=$((fail_count + 1))
	fi
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  expected substring=%q\n  actual=%q\n' "$label" "$needle" "$haystack" >&2
		fail_count=$((fail_count + 1))
	fi
}

# ---------------------------------------------------------------------------
# Invariant 1: the broken pattern must crash bash 3.2.
# ---------------------------------------------------------------------------
# Run the exact broken pattern in a subprocess so its crash doesn't kill
# this test. We expect non-zero exit AND the "bad substitution" error on
# stderr.
bash32_output=$(/bin/bash -c 'refs="foo"; blocker_task_ids="${refs%%$'"'"'\0'"'"'*}"; echo OK tids=[$blocker_task_ids]' 2>&1 || true)
bash32_rc=0
/bin/bash -c 'refs="foo"; blocker_task_ids="${refs%%$'"'"'\0'"'"'*}"; echo OK' >/dev/null 2>&1 || bash32_rc=$?

if [[ "$(/bin/bash --version | head -1)" == *"3.2"* ]]; then
	assert_contains "bash 3.2 broken pattern crashes with 'bad substitution'" "bad substitution" "$bash32_output"
	if [[ "$bash32_rc" -ne 0 ]]; then
		printf 'PASS: bash 3.2 broken pattern exits non-zero (rc=%d)\n' "$bash32_rc"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: bash 3.2 broken pattern should exit non-zero but exited 0\n' >&2
		fail_count=$((fail_count + 1))
	fi
else
	printf 'SKIP: not running under bash 3.2 — cannot verify the crash invariant\n'
fi

# ---------------------------------------------------------------------------
# Invariant 2: split helpers return correct values.
# ---------------------------------------------------------------------------
if [[ ! -f "$DEP_GRAPH" ]]; then
	printf 'FAIL: cannot locate pulse-dep-graph.sh at %s\n' "$DEP_GRAPH" >&2
	exit 1
fi

# Source the helper functions in a clean subshell. The helper file pulls in
# a lot of pulse context; source inside `(...)` so we don't pollute.
test_extract() {
	local body="$1"
	local want_tids="$2"
	local want_nums="$3"
	local label="$4"
	local got_tids got_nums
	# shellcheck disable=SC1090
	got_tids=$(bash -c "source '$DEP_GRAPH' 2>/dev/null; _blocked_by_extract_tids \"\$1\" | tr '\n' ','" _ "$body" | sed 's/,$//')
	# shellcheck disable=SC1090
	got_nums=$(bash -c "source '$DEP_GRAPH' 2>/dev/null; _blocked_by_extract_nums \"\$1\" | tr '\n' ','" _ "$body" | sed 's/,$//')
	assert_eq "${label} tids" "$want_tids" "$got_tids"
	assert_eq "${label} nums" "$want_nums" "$got_nums"
}

# Empty body: both helpers return empty. Before the fix, this crashed the
# parent shell on the subsequent `${refs%%$'\0'*}` line.
test_extract '' '' '' 'empty body'

# Body with no blocked-by markers: both helpers return empty.
test_extract 'Just a regular issue body with no dependencies.' '' '' 'no markers'

# Body with a single task-ID blocker.
test_extract 'blocked-by:t143' '143' '' 'single tid bare'

# Body with a single issue-number blocker.
test_extract 'blocked-by:#18429' '' '18429' 'single num bare'

# Body with mixed tid and num.
test_extract $'blocked-by:t143\nblocked-by:#18429' '143' '18429' 'mixed tid and num'

# Realistic issue body fragment.
test_extract "$(
	cat <<'EOF'
## What

Do the thing.

## Blocked-by

blocked-by:t200
blocked-by:#19000
EOF
)" '200' '19000' 'realistic body'

# ---------------------------------------------------------------------------
# Invariant 3: no surviving `${...$'\0'...}` patterns in shell code.
# ---------------------------------------------------------------------------
# Grep for the specific anti-pattern in actual code (not comments, not this
# test file itself). A future change that reintroduces NUL inside a
# parameter expansion must be caught at test time, not in production.
#
# Strategy: match lines that contain the pattern but that do NOT start
# (after optional leading whitespace) with `#` (a comment). The test file
# is excluded by --exclude so the grep doesn't catch its own documentation.
nul_in_expansion=$(
	grep -rn -E '\$\{[^}]*\$'"'"'\\0' "$REPO_ROOT/.agents/scripts/" \
		--include='*.sh' \
		--exclude='test-pulse-dep-graph-bash32-nul-crash.sh' 2>/dev/null |
		grep -vE ':[[:space:]]*#' || true
)
if [[ -z "$nul_in_expansion" ]]; then
	printf 'PASS: no ${...$'"'"'\\0...} patterns in shell code\n'
	pass_count=$((pass_count + 1))
else
	printf 'FAIL: found NUL-in-parameter-expansion pattern (bash 3.2 will crash):\n%s\n' "$nul_in_expansion" >&2
	fail_count=$((fail_count + 1))
fi

printf '\nResults: %d passed, %d failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi
printf 'GH#18830 regression test: all invariants hold.\n'
exit 0
