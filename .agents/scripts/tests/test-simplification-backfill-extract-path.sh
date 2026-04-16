#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-simplification-backfill-extract-path.sh — regression guard for GH#19370.
#
# The complexity scanner produces three issue-title formats:
#
#   A) "simplification: tighten agent doc <path> (<N> lines)"                           (no topic label)
#   B) "simplification: tighten agent doc <topic> (<path>, <N> lines)"                  (topic label — path in parens)
#   C) "simplification: reduce function complexity in <path> (<N> functions ...)"      (function complexity)
#
# _simplification_backfill_extract_file_path() in pulse-simplification-state.sh
# must return a clean repo-relative path for all three. Before GH#19370 the
# character class excluded space/comma/close-paren but NOT open-paren, so form
# B captured "(.agents/…" with a leading "(". The downstream
# "[[ -f ${repo_path}/${file_path} ]] && continue" check in
# _simplification_state_backfill_closed then silently skipped every
# topic-labeled issue, so state never recorded these files and the scanner
# re-flagged them on every cycle (observed: 8 thrash cycles on
# shell-style-guide.md, 9 on pre-dispatch-validators.md).
#
# This test pins the clean output for all three forms so a future regex
# change cannot silently regress form B.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
STATE_SCRIPT="${SCRIPT_DIR}/../pulse-simplification-state.sh"

# Pattern B fallback — the test file stands alone on `readonly`-prefixed names
# (no collision with shared-constants.sh).
readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

# The state module uses an include guard and expects $_PULSE_SIMPLIFICATION_STATE_LOADED
# to be unset on first source. It also references $LOGFILE via ${LOGFILE:-/dev/null},
# so we do not need to set LOGFILE here.
# shellcheck source=/dev/null
source "$STATE_SCRIPT"

assert_extract() {
	local test_name="$1"
	local title="$2"
	local expected="$3"

	local actual
	actual=$(_simplification_backfill_extract_file_path "$title")
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$actual" == "$expected" ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	printf '       title:    %s\n' "$title"
	printf '       expected: %q\n' "$expected"
	printf '       actual:   %q\n' "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Form A: no topic label — path appears before a parenthetical "(N lines)".
assert_extract \
	"form A (no topic label) — .md path" \
	"simplification: tighten agent doc .agents/reference/example.md (99 lines)" \
	".agents/reference/example.md"

assert_extract \
	"form A (no topic label) — .sh path" \
	"simplification: tighten agent doc .agents/scripts/example.sh (120 lines)" \
	".agents/scripts/example.sh"

# Form B: topic label present — path is wrapped in "(<path>, <N> lines)".
# This is the form the GH#19370 regex bug mishandled.
assert_extract \
	"form B (topic label) — .md path, GH#19370 regression" \
	"simplification: tighten agent doc Shell Helper Style Guide (.agents/reference/shell-style-guide.md, 135 lines)" \
	".agents/reference/shell-style-guide.md"

assert_extract \
	"form B (topic label) — .md path, second case" \
	"simplification: tighten agent doc Pre-Dispatch Validators (.agents/reference/pre-dispatch-validators.md, 82 lines)" \
	".agents/reference/pre-dispatch-validators.md"

# Form C: function-complexity variant — path appears before "(N functions ...)".
assert_extract \
	"form C (function complexity) — .sh path" \
	"simplification: reduce function complexity in .agents/scripts/pulse-wrapper.sh (46 functions >100 lines)" \
	".agents/scripts/pulse-wrapper.sh"

# Recheck-prefixed titles (t1754 recheck flow) wrap the underlying title
# verbatim. The regex must still resolve the path for both forms A and B.
assert_extract \
	"recheck prefix + form A" \
	"recheck: simplification: tighten agent doc .agents/reference/example.md (99 lines)" \
	".agents/reference/example.md"

assert_extract \
	"recheck prefix + form B (topic label)" \
	"recheck: simplification: tighten agent doc Shell Helper Style Guide (.agents/reference/shell-style-guide.md, 135 lines)" \
	".agents/reference/shell-style-guide.md"

# Edge: no matching path in title returns empty (caller distinguishes via
# empty output, not exit code).
assert_extract \
	"no path in title returns empty" \
	"simplification: something something with no extension at all" \
	""

printf '\n'
printf '%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
