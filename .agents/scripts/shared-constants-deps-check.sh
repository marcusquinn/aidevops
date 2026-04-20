#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# shared-constants-deps-check.sh (t2431)
# =============================================================================
# Layer 3 / Layer 4 guard for the test-harness `shared-constants.sh` split
# regression class (issue #20069).
#
# Two responsibilities, both run as a single check:
#   1. `layer3` — ban bare `cp .../shared-constants.sh ...` in test files
#      outside of `.agents/scripts/tests/lib/test-helpers.sh`. Bare copies are
#      the exact pattern that caused test-gh-wrapper-auto-sig.sh and
#      test-comment-wrapper-marker-dedup.sh to silently exit 0 after PR #20037
#      split out `shared-gh-wrappers.sh`. The only legitimate caller is the
#      helper itself, which knows the current dep graph.
#   2. `layer4` — verify that `_test_discover_shared_deps` (run against the
#      on-disk `shared-constants.sh`) still succeeds and returns at least one
#      sibling. This is a lightweight sanity check that the parser contract
#      (match `source "${_SC_SELF%/*}/<file>.sh"` on a line by itself) still
#      holds after any edit to shared-constants.sh. If shared-constants.sh is
#      ever rewritten in a way that uses a different sibling-source syntax,
#      this check will flag it immediately.
#
# Exit 0  = clean, all guards pass
# Exit 1  = found bare `cp` outside the helper (Layer 3 failure)
# Exit 2  = parser returned no siblings from shared-constants.sh — only an
#           error when shared-constants.sh *does* have `source` directives
#           for sub-libraries (otherwise legitimate state = exit 0). Best-effort
#           heuristic: if a grep for `source "${_SC_SELF%/*}/` finds matches
#           and the parser returns zero, something is wrong.
# Exit 3  = invalid invocation / missing prerequisite file.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 3
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit 3

TESTS_DIR="${SCRIPT_DIR}/tests"
HELPER_REL_PATH="tests/lib/test-helpers.sh"
SHARED_CONSTANTS="${SCRIPT_DIR}/shared-constants.sh"

# Colors (only when stdout is a TTY so CI logs stay readable).
if [[ -t 1 ]]; then
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[0;33m'
	RESET=$'\033[0m'
else
	RED=""
	GREEN=""
	YELLOW=""
	RESET=""
fi

fail() {
	local msg="$1"
	printf '%sFAIL:%s %s\n' "$RED" "$RESET" "$msg" >&2
	return 0
}

ok() {
	local msg="$1"
	printf '%sOK:%s %s\n' "$GREEN" "$RESET" "$msg"
	return 0
}

warn() {
	local msg="$1"
	printf '%sWARN:%s %s\n' "$YELLOW" "$RESET" "$msg" >&2
	return 0
}

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
if [[ ! -d "$TESTS_DIR" ]]; then
	fail "tests directory not found: $TESTS_DIR"
	exit 3
fi
if [[ ! -f "$SHARED_CONSTANTS" ]]; then
	fail "shared-constants.sh not found: $SHARED_CONSTANTS"
	exit 3
fi

# -----------------------------------------------------------------------------
# Layer 3: ban bare `cp shared-constants.sh` outside the helper
# -----------------------------------------------------------------------------
# Strategy: grep every file under .agents/scripts/tests/ for a `cp` call that
# includes the string "shared-constants.sh". Exclude the helper file itself
# (the one legitimate home for this pattern).
#
# False-positive guardrails:
#  - We require `cp` to appear as a word (\bcp\b via -w), not inside another
#    identifier.
#  - We require the target filename to be the exact string "shared-constants.sh"
#    (otherwise helper-internal comments that merely mention the name wouldn't
#    trigger — but we DO grep code, so any comment-only hit is acceptable noise
#    to flag).
#
# Output: a list of offending `file:line: <line>` entries.

layer3_check() {
	local bad=0
	local offenders
	# Strip inline comments before matching so test-file docstrings that
	# describe the forbidden pattern (e.g. "use _test_copy_shared_deps
	# rather than a bare `cp shared-constants.sh`") don't false-positive.
	# Match `cp` only when it appears as a command (at line start or after
	# a shell-command boundary: whitespace, `;`, `&&`, `||`, `|`, `(`).
	# The helper file itself is the one legitimate home for this pattern.
	local helper_abs="${SCRIPT_DIR}/${HELPER_REL_PATH}"
	offenders=$(
		find "$TESTS_DIR" -name '*.sh' -type f -not -path "$helper_abs" -print0 2>/dev/null |
			while IFS= read -r -d '' file; do
				awk -v f="$file" '
					{
						line = $0
						# Strip from the first # onwards (naive but safe for our codebase).
						sub(/#.*/, "", line)
						if (line ~ /(^|[[:space:];&|(])cp([[:space:]]|$)/ && line ~ /shared-constants\.sh/) {
							print f ":" NR ": " $0
						}
					}
				' "$file"
			done
	)
	if [[ -n "$offenders" ]]; then
		fail "Layer 3: bare \`cp shared-constants.sh\` outside $HELPER_REL_PATH:"
		printf '%s\n' "$offenders" | sed 's/^/  /' >&2
		printf '\n' >&2
		printf '%sFix:%s replace the bare cp with:\n' "$YELLOW" "$RESET" >&2
		# shellcheck disable=SC2016  # literal snippet intended for user to copy
		printf '  source "${SCRIPT_DIR}/lib/test-helpers.sh"\n' >&2
		# shellcheck disable=SC2016
		printf '  _test_copy_shared_deps "$PARENT_DIR" "$TMPDIR_TEST" || exit 1\n' >&2
		# shellcheck disable=SC2016
		printf '  _test_source_shared_deps "$TMPDIR_TEST" || exit 1\n' >&2
		bad=1
	else
		ok "Layer 3: no bare \`cp shared-constants.sh\` outside helper"
	fi
	return "$bad"
}

# -----------------------------------------------------------------------------
# Layer 4: verify parser contract still holds
# -----------------------------------------------------------------------------
# The helper's discovery regex is a single simple pattern:
#   awk '/^source[[:space:]]/ && /_SC_SELF/ { ... }'
#
# If shared-constants.sh *has* sibling source directives (detectable via a
# cheap grep), the helper MUST return a non-empty list. If the cheap grep
# finds matches but the parser returns zero, either the parser broke OR
# shared-constants.sh switched to a new syntax — both are actionable.

layer4_check() {
	local helper_path="${SCRIPT_DIR}/${HELPER_REL_PATH}"
	if [[ ! -f "$helper_path" ]]; then
		fail "Layer 4: helper missing — $helper_path"
		return 1
	fi

	# Cheap grep: count candidate sibling-source lines.
	local cheap_count
	cheap_count=$(grep -cE '^source[[:space:]]+"\$\{_SC_SELF%/\*\}/' "$SHARED_CONSTANTS" || true)
	cheap_count=${cheap_count:-0}

	# Call the parser in a subshell so its errors / output don't leak.
	local parsed_count=0
	local parsed_out
	parsed_out=$(
		# shellcheck disable=SC1090
		source "$helper_path"
		_test_discover_shared_deps "$SCRIPT_DIR"
	)
	if [[ -n "$parsed_out" ]]; then
		parsed_count=$(printf '%s\n' "$parsed_out" | wc -l | tr -d ' ')
	fi

	if [[ "$cheap_count" -eq 0 ]] && [[ "$parsed_count" -eq 0 ]]; then
		ok "Layer 4: shared-constants.sh has no sub-library sources (nothing to parse)"
		return 0
	fi

	if [[ "$cheap_count" -gt 0 ]] && [[ "$parsed_count" -eq 0 ]]; then
		fail "Layer 4: shared-constants.sh has $cheap_count sibling source lines but parser found 0"
		warn "The helper's discovery regex no longer matches the source syntax."
		warn "Grep candidate lines:"
		grep -nE '^source[[:space:]]+"\$\{_SC_SELF%/\*\}/' "$SHARED_CONSTANTS" | sed 's/^/  /' >&2
		return 1
	fi

	ok "Layer 4: parser found $parsed_count of $cheap_count sibling source lines"
	if [[ "$cheap_count" -ne "$parsed_count" ]]; then
		warn "Parser and grep disagree on count ($parsed_count vs $cheap_count); sources may use variants."
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
	local rc=0
	layer3_check || rc=1
	layer4_check || rc=${rc:-0}  # keep layer 3 exit code if that one failed too

	if [[ "$rc" -eq 0 ]]; then
		ok "all shared-constants deps checks passed"
	fi
	return "$rc"
}

main "$@"
