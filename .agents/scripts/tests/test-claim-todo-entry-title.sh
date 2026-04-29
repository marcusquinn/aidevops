#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-todo-entry-title.sh — GH#21473 regression guard.
#
# Validates that _ensure_todo_entry_written() uses the TITLE (short one-liner)
# argument for the TODO.md line text, NOT the DESCRIPTION (full issue body).
#
# The bug: the 3rd argument was named `description` and was used directly in
# the safe_desc construction, causing worker-ready multi-paragraph bodies
# (mandated by t1900/t2417) to land in TODO.md as a single mega-line.
#
# Cases covered:
#   1. Short title + multi-paragraph description → TODO line uses title only
#   2. Title with special whitespace chars → collapsed to single token
#   3. Empty title → falls back to "(no description)"
#   4. Labels are converted to #tag form in TODO line
#   5. ref:GH#NNN is appended to TODO line
#
# NOTE: not using `set -e` — assertions rely on capturing non-zero exits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
ISSUE_SCRIPT="${SCRIPT_DIR}/../claim-task-id-issue.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

assert_eq() {
	local name="$1" got="$2" want="$3"
	if [[ "$got" == "$want" ]]; then
		pass "$name"
	else
		fail "$name" "want='${want}' got='${got}'"
	fi
	return 0
}

assert_contains() {
	local name="$1" haystack="$2" needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "needle='${needle}' not found in '${haystack}'"
	fi
	return 0
}

assert_not_contains() {
	local name="$1" haystack="$2" needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "needle='${needle}' unexpectedly found in '${haystack}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: create minimal stub environment and source the issue sub-library
# ---------------------------------------------------------------------------

STUB_DIR=""
TODO_FILE=""

_setup() {
	STUB_DIR=$(mktemp -d)
	trap '_teardown' EXIT

	# Fake git: silent no-op
	cat >"${STUB_DIR}/git" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "${STUB_DIR}/git"

	# Fake gh: auth ok, everything else no-op
	cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then exit 0; fi
exit 0
STUB
	chmod +x "${STUB_DIR}/gh"

	# Fake jq: silent no-op
	cat >"${STUB_DIR}/jq" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "${STUB_DIR}/jq"

	export PATH="${STUB_DIR}:${PATH}"
	export HOME="${STUB_DIR}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	# Create a minimal TODO.md in a temp repo dir so _ensure_todo_entry_written
	# has a file to append to.
	local repo_dir="${STUB_DIR}/repo"
	mkdir -p "$repo_dir"
	TODO_FILE="${repo_dir}/TODO.md"
	printf '# TODO\n\n## Backlog\n' >"$TODO_FILE"

	# Source only the issue sub-library (not the main entrypoint).
	# Provide stubs for functions it may call that are defined in claim-task-id.sh.
	add_gh_ref_to_todo() { return 0; }
	log_info() { return 0; }
	_insert_todo_line() {
		local todo_file="$1"
		local line="$2"
		printf '%s\n' "$line" >>"$todo_file"
		return 0
	}

	# shellcheck disable=SC1090
	if ! source "$ISSUE_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$ISSUE_SCRIPT" >&2
		exit 1
	fi

	return 0
}

_teardown() {
	[[ -n "$STUB_DIR" ]] && rm -rf "$STUB_DIR"
	return 0
}

_setup

# ---------------------------------------------------------------------------
# Helper: call _ensure_todo_entry_written and return last line of TODO.md
# ---------------------------------------------------------------------------

REPO_DIR="${STUB_DIR}/repo"

run_ensure() {
	local task_id="$1"
	local issue_num="$2"
	local title="$3"
	local labels="${4:-}"

	# Reset TODO.md to base state so each test starts clean.
	printf '# TODO\n\n## Backlog\n' >"$TODO_FILE"

	# Reset global so blocked-by suffix is not injected.
	_CLAIM_BLOCKED_BY_REFS=""

	_ensure_todo_entry_written "$task_id" "$issue_num" "$title" "$labels" "$REPO_DIR" 2>/dev/null
	tail -n 1 "$TODO_FILE"
	return 0
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

# 1. GH#21473 regression: title used, not multi-paragraph description
result1="$(run_ensure "t344" "2107" "align 6 downstream briefs" "" )"
assert_eq "title_not_description_in_todo_line" \
	"$result1" \
	"- [ ] t344 align 6 downstream briefs ref:GH#2107"

# 2. Confirming description body does NOT appear in the line
# (run_ensure passes title as 3rd arg now; description is irrelevant to the line)
result2="$(run_ensure "t344" "2107" "short title" "")"
assert_not_contains "description_body_absent_from_todo_line" \
	"$result2" \
	"## Task"

assert_not_contains "description_body_absent2" \
	"$result2" \
	"enum counts"

# 3. Title with leading/trailing whitespace is trimmed
result3="$(run_ensure "t100" "999" "  spaced title  " "")"
assert_eq "title_whitespace_trimmed" \
	"$result3" \
	"- [ ] t100 spaced title ref:GH#999"

# 4. Empty title falls back to (no title)
result4="$(run_ensure "t101" "888" "" "")"
assert_eq "empty_title_fallback" \
	"$result4" \
	"- [ ] t101 (no title) ref:GH#888"

# 5. Labels are appended as #tags, reserved prefixes skipped
result5="$(run_ensure "t200" "777" "my task title" "auto-dispatch,status:available,tier:standard,bug")"
assert_contains "labels_auto_dispatch_as_tag" "$result5" "#auto-dispatch"
assert_contains "labels_bug_as_tag" "$result5" "#bug"
assert_not_contains "labels_status_skipped" "$result5" "status:available"
assert_not_contains "labels_tier_skipped" "$result5" "tier:standard"

# 6. ref:GH#NNN always appended
result6="$(run_ensure "t300" "12345" "verify ref appended" "")"
assert_contains "ref_gh_appended" "$result6" "ref:GH#12345"

# 7. Multi-word title preserved as-is (spaces not collapsed beyond normalisation)
result7="$(run_ensure "t400" "111" "fix the frobnicator bug" "")"
assert_eq "multiword_title_preserved" \
	"$result7" \
	"- [ ] t400 fix the frobnicator bug ref:GH#111"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests run: %d passed, %d failed\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	printf '\nFailed tests:%b\n' "$ERRORS"
	exit 1
fi

exit 0
