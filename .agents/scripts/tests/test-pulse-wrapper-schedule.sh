#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-wrapper-schedule.sh — Tests for check_repo_pulse_schedule() (GH#6510)
#
# Tests:
#   - No schedule fields: always included
#   - pulse_hours normal window: in-window and out-of-window
#   - pulse_hours overnight window (start > end): in-window and out-of-window
#   - pulse_expires: not yet expired, expired today, expired yesterday
#   - pulse_expires auto-disable: sets pulse:false in repos.json
#   - Bash 3.2 compatibility: zero-padded hours (08, 09) handled correctly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	export LOGFILE
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

make_repos_json() {
	local path="$1"
	local slug="$2"
	local extra_fields="${3:-}"
	cat >"$path" <<EOF
{
  "initialized_repos": [
    {
      "path": "/tmp/test-repo",
      "slug": "${slug}",
      "pulse": true${extra_fields}
    }
  ]
}
EOF
	return 0
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_no_schedule_fields_always_included() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	if check_repo_pulse_schedule "owner/repo" "" "" "" "$repos_json"; then
		print_result "no schedule fields: always included" 0
	else
		print_result "no schedule fields: always included" 1 "Expected exit 0 (include), got 1 (skip)"
	fi
	return 0
}

test_pulse_hours_in_window_normal() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Normal window 9→17: hour 12 should be in window
	# Override date to return hour 12
	date() {
		if [[ "${1:-}" == "+%H" ]]; then
			printf '12'
			return 0
		fi
		command date "$@"
		return $?
	}
	export -f date 2>/dev/null || true

	if check_repo_pulse_schedule "owner/repo" "9" "17" "" "$repos_json"; then
		print_result "pulse_hours normal window: hour 12 in 9→17" 0
	else
		print_result "pulse_hours normal window: hour 12 in 9→17" 1 "Expected exit 0 (in window)"
	fi

	unset -f date 2>/dev/null || true
	return 0
}

test_pulse_hours_out_of_window_normal() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Normal window 9→17: hour 20 should be outside
	date() {
		if [[ "${1:-}" == "+%H" ]]; then
			printf '20'
			return 0
		fi
		command date "$@"
		return $?
	}
	export -f date 2>/dev/null || true

	if check_repo_pulse_schedule "owner/repo" "9" "17" "" "$repos_json"; then
		print_result "pulse_hours normal window: hour 20 outside 9→17" 1 "Expected exit 1 (skip), got 0 (include)"
	else
		print_result "pulse_hours normal window: hour 20 outside 9→17" 0
	fi

	unset -f date 2>/dev/null || true
	return 0
}

test_pulse_hours_in_window_overnight_after_start() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Overnight window 17→5: hour 22 should be in window (>= 17)
	date() {
		if [[ "${1:-}" == "+%H" ]]; then
			printf '22'
			return 0
		fi
		command date "$@"
		return $?
	}
	export -f date 2>/dev/null || true

	if check_repo_pulse_schedule "owner/repo" "17" "5" "" "$repos_json"; then
		print_result "pulse_hours overnight window: hour 22 in 17→5 (after start)" 0
	else
		print_result "pulse_hours overnight window: hour 22 in 17→5 (after start)" 1 "Expected exit 0 (in window)"
	fi

	unset -f date 2>/dev/null || true
	return 0
}

test_pulse_hours_in_window_overnight_before_end() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Overnight window 17→5: hour 3 should be in window (< 5)
	date() {
		if [[ "${1:-}" == "+%H" ]]; then
			printf '03'
			return 0
		fi
		command date "$@"
		return $?
	}
	export -f date 2>/dev/null || true

	if check_repo_pulse_schedule "owner/repo" "17" "5" "" "$repos_json"; then
		print_result "pulse_hours overnight window: hour 03 in 17→5 (before end)" 0
	else
		print_result "pulse_hours overnight window: hour 03 in 17→5 (before end)" 1 "Expected exit 0 (in window)"
	fi

	unset -f date 2>/dev/null || true
	return 0
}

test_pulse_hours_out_of_window_overnight() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Overnight window 17→5: hour 10 should be outside (>= 5 and < 17)
	date() {
		if [[ "${1:-}" == "+%H" ]]; then
			printf '10'
			return 0
		fi
		command date "$@"
		return $?
	}
	export -f date 2>/dev/null || true

	if check_repo_pulse_schedule "owner/repo" "17" "5" "" "$repos_json"; then
		print_result "pulse_hours overnight window: hour 10 outside 17→5" 1 "Expected exit 1 (skip), got 0 (include)"
	else
		print_result "pulse_hours overnight window: hour 10 outside 17→5" 0
	fi

	unset -f date 2>/dev/null || true
	return 0
}

test_pulse_hours_zero_padded_hours_bash32() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Bash 3.2 octal trap: hour 08 must not be treated as invalid octal
	# Normal window 7→9: hour 08 should be in window
	date() {
		if [[ "${1:-}" == "+%H" ]]; then
			printf '08'
			return 0
		fi
		command date "$@"
		return $?
	}
	export -f date 2>/dev/null || true

	if check_repo_pulse_schedule "owner/repo" "7" "9" "" "$repos_json"; then
		print_result "pulse_hours bash3.2 octal: hour 08 in 7→9 (zero-padded)" 0
	else
		print_result "pulse_hours bash3.2 octal: hour 08 in 7→9 (zero-padded)" 1 "Expected exit 0 — 10# prefix must strip octal interpretation"
	fi

	unset -f date 2>/dev/null || true
	return 0
}

test_pulse_expires_not_yet_expired() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Expires tomorrow — should be included
	local tomorrow
	tomorrow=$(date -v+1d +%Y-%m-%d 2>/dev/null || date -d "+1 day" +%Y-%m-%d 2>/dev/null || echo "2099-12-31")

	if check_repo_pulse_schedule "owner/repo" "" "" "$tomorrow" "$repos_json"; then
		print_result "pulse_expires: not yet expired (tomorrow)" 0
	else
		print_result "pulse_expires: not yet expired (tomorrow)" 1 "Expected exit 0 (not expired)"
	fi
	return 0
}

test_pulse_expires_expired_yesterday() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Expired yesterday — should be skipped and pulse:false written
	local yesterday
	yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "-1 day" +%Y-%m-%d 2>/dev/null || echo "2000-01-01")

	if check_repo_pulse_schedule "owner/repo" "" "" "$yesterday" "$repos_json"; then
		print_result "pulse_expires: expired yesterday" 1 "Expected exit 1 (expired), got 0 (include)"
	else
		print_result "pulse_expires: expired yesterday" 0
	fi
	return 0
}

test_pulse_expires_auto_disables_in_repos_json() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	local yesterday
	yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "-1 day" +%Y-%m-%d 2>/dev/null || echo "2000-01-01")

	# Run the check — should auto-disable
	check_repo_pulse_schedule "owner/repo" "" "" "$yesterday" "$repos_json" || true

	# Verify pulse:false was written
	if command -v jq &>/dev/null; then
		local pulse_val
		pulse_val=$(jq -r '.initialized_repos[] | select(.slug == "owner/repo") | .pulse' "$repos_json" 2>/dev/null)
		if [[ "$pulse_val" == "false" ]]; then
			print_result "pulse_expires: auto-disables pulse:false in repos.json" 0
		else
			print_result "pulse_expires: auto-disables pulse:false in repos.json" 1 "Expected pulse:false, got '${pulse_val}'"
		fi
	else
		print_result "pulse_expires: auto-disables pulse:false in repos.json" 0 "(jq not available — skipped)"
	fi
	return 0
}

test_pulse_expires_today_boundary() {
	local repos_json="${TEST_ROOT}/repos.json"
	make_repos_json "$repos_json" "owner/repo"

	# Expires today — NOT expired (today > expires is false when equal)
	local today
	today=$(date +%Y-%m-%d)

	if check_repo_pulse_schedule "owner/repo" "" "" "$today" "$repos_json"; then
		print_result "pulse_expires: expires today is NOT expired (boundary)" 0
	else
		print_result "pulse_expires: expires today is NOT expired (boundary)" 1 "Expected exit 0 — expires today means still active today"
	fi
	return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

setup_test_env

test_no_schedule_fields_always_included
test_pulse_hours_in_window_normal
test_pulse_hours_out_of_window_normal
test_pulse_hours_in_window_overnight_after_start
test_pulse_hours_in_window_overnight_before_end
test_pulse_hours_out_of_window_overnight
test_pulse_hours_zero_padded_hours_bash32
test_pulse_expires_not_yet_expired
test_pulse_expires_expired_yesterday
test_pulse_expires_auto_disables_in_repos_json
test_pulse_expires_today_boundary

teardown_test_env

echo ""
echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
