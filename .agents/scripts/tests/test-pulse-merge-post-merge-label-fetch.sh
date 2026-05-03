#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-post-merge-label-fetch.sh — GH#22219 regression guard.
#
# Verifies _handle_post_merge_actions behaviour around optional PR labels:
# a provided empty 5th argument is authoritative and must not refetch, while an
# omitted 5th argument falls back to fetching PR labels before setting solved
# attribution.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_FILE="${SCRIPT_DIR_TEST}/../pulse-merge.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '     %s\n' "$detail"
	fi
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export SOLVED_LABEL_LOG="${TEST_ROOT}/solved-labels.log"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"

	export AGENTS_DIR="${TEST_ROOT}"
	mkdir -p "${AGENTS_DIR}/scripts"
	cat >"${AGENTS_DIR}/scripts/gh-signature-helper.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${AGENTS_DIR}/scripts/gh-signature-helper.sh"

	export PULSE_START_EPOCH
	PULSE_START_EPOCH=$(date +%s)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_function_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_pm_issue_api\(\) \{/,/^}$/ { print }
		/^_pm_build_closing_comment\(\) \{/,/^}$/ { print }
		/^_handle_post_merge_actions\(\) \{/,/^}$/ { print }
	' "$MERGE_FILE")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract _handle_post_merge_actions from %s\n' "$MERGE_FILE" >&2
		return 1
	fi
	eval "$fn_src"
	return 0
}

install_helper_stubs() {
	gh() {
		printf '%s\n' "$*" >>"$GH_CALL_LOG"
		if [[ "$1" == "api" && "$*" == *"/comments"* ]]; then
			printf '[]\n'
		fi
		return 0
	}

	gh_pr_comment() {
		gh pr comment "$@"
		return 0
	}
	gh_issue_comment() {
		gh issue comment "$@"
		return 0
	}
	gh_pr_view() {
		printf 'pr view %s\n' "$*" >>"$GH_CALL_LOG"
		printf '%s\n' "${TEST_PR_LABELS:-}"
		return 0
	}
	set_solved_label() {
		local issue="$1"
		local repo="$2"
		local actor="$3"
		printf '%s %s %s\n' "$issue" "$repo" "$actor" >>"$SOLVED_LABEL_LOG"
		return 0
	}
	unlock_issue_after_worker() { return 0; }
	fast_fail_reset() { return 0; }
	_release_interactive_claim_on_merge() { return 0; }
	auto_file_next_phase() { return 0; }
	_unblock_circuit_breaker_meta_pr() { return 0; }
	return 0
}

assert_log_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label" "Expected pattern '$pattern' in $file"
	fi
	return 0
}

assert_log_not_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		fail "$label" "Unexpected pattern '$pattern' in $file"
	else
		pass "$label"
	fi
	return 0
}

test_provided_empty_pr_labels_skip_refetch() {
	: >"$GH_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"
	export TEST_PR_LABELS="origin:worker"

	_handle_post_merge_actions "22585" "marcusquinn/aidevops" "22219" "merged" ""

	assert_log_not_contains "$GH_CALL_LOG" "pr view" \
		"provided empty pr_labels skips fallback fetch"
	assert_log_contains "$SOLVED_LABEL_LOG" "22219 marcusquinn/aidevops interactive" \
		"provided empty pr_labels keeps interactive solved attribution"
	return 0
}

test_omitted_pr_labels_fetches_fallback() {
	: >"$GH_CALL_LOG"
	: >"$SOLVED_LABEL_LOG"
	export TEST_PR_LABELS="origin:worker"

	_handle_post_merge_actions "22585" "marcusquinn/aidevops" "22219" "merged"

	assert_log_contains "$GH_CALL_LOG" "pr view 22585" \
		"omitted pr_labels fetches fallback labels"
	assert_log_contains "$SOLVED_LABEL_LOG" "22219 marcusquinn/aidevops worker" \
		"fallback labels drive worker solved attribution"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	define_function_under_test
	install_helper_stubs

	test_provided_empty_pr_labels_skip_refetch
	test_omitted_pr_labels_fetches_fallback

	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
