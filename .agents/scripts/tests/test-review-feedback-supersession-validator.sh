#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-review-feedback-supersession-validator.sh — t3569/GH#23101 fixtures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../pre-dispatch-validator-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	GH_LOG="${TEST_ROOT}/gh.log"
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_LOG
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

write_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail

scenario="${STUB_SCENARIO:-}"
log_file="${GH_LOG:?}"

log_call() {
	printf '%s\n' "$*" >>"$log_file"
	return 0
}

arg_string="$*"
endpoint=""
for arg in "$@"; do
	case "$arg" in
	search/issues | repos/owner/repo/*)
		endpoint="$arg"
		break
		;;
	esac
done

if [[ "${1:-}" == "api" && "$endpoint" == repos/owner/repo/issues/* && "$endpoint" != */comments ]]; then
	case "$arg_string" in
	*'.body // ""'*)
		case "$scenario" in
		source-clear | source-ambiguous | source-fetch-failure)
			printf '**Source PR**: #50\n\n## Files to modify\n- `.agents/scripts/review-hook.sh`\n\n## Finding\nAdd the event payload guard before worker launch.\n'
			;;
		malformed-source-clear)
			printf '**Source PR**: pending\n\n## Files to modify\n- `.agents/scripts/review-hook.sh`\n\n## Finding\nAdd the event payload guard before worker launch.\n'
			;;
		no-file)
			printf '**Source PR**: #50\n\n## Finding\nAdd the event payload guard before worker launch.\n'
			;;
		*)
			printf '## Files to modify\n- `.agents/scripts/review-hook.sh`\n\n## Finding\nAdd the event payload guard before worker launch.\n'
			;;
		esac
		;;
	*'@tsv'*)
		case "$scenario" in
		source-clear | source-ambiguous | source-fetch-failure | no-file)
			printf '2026-05-02T10:00:00Z\treview-feedback: event payload guard\tquality-debt,source:review-feedback,tier:thinking\n'
			;;
		malformed-source-clear)
			printf '2026-05-02T10:00:00Z\tReview followup: PR #50 — event payload guard\tquality-debt,source:review-feedback,tier:thinking\n'
			;;
		*)
			printf '2026-05-01T10:00:00Z\treview-feedback: event payload guard\tquality-debt,source:review-feedback,tier:thinking\n'
			;;
		esac
		;;
	*'join(",")'*)
		printf 'quality-debt,source:review-feedback,tier:thinking\n'
		;;
	*)
		printf '{}\n'
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == "repos/owner/repo/issues/100/comments" ]]; then
	printf '0\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == "search/issues" ]]; then
	case "$scenario" in
	clear) printf '200\n' ;;
	ambiguous) printf '201\n' ;;
	source-clear) printf '200\n' ;;
	malformed-source-clear) printf '200\n' ;;
	source-ambiguous) printf '201\n' ;;
	source-fetch-failure) printf '200\n' ;;
	no-file) printf '200\n' ;;
	none) printf '' ;;
	before) printf '203\n' ;;
	*) printf '' ;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == repos/owner/repo/pulls/* && "$endpoint" != */files ]]; then
	pr_number="${endpoint##*/}"
	if [[ "$pr_number" == "50" ]]; then
		if [[ "$scenario" == "source-fetch-failure" ]]; then
			exit 1
		fi
		printf '2026-05-01T09:30:00Z\n'
		exit 0
	fi
	case "$pr_number" in
	200)
		printf '2026-05-01T11:00:00Z\tfix event payload guard\tAdds a guard for event payload handling.\n'
		;;
	201)
		printf '2026-05-01T11:00:00Z\trefactor review hook logging\tRenames local variables only.\n'
		;;
	203)
		printf '2026-05-01T09:00:00Z\tfix event payload guard\tAdds a guard for event payload handling.\n'
		;;
	*)
		printf '\t\t\n'
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "api" && "$endpoint" == repos/owner/repo/pulls/*/files ]]; then
	pr_number="${endpoint%/files}"
	pr_number="${pr_number##*/}"
	case "$arg_string" in
	*'.filename'*)
		case "$pr_number" in
		200 | 201 | 203) printf '.agents/scripts/review-hook.sh\n' ;;
		*) printf '' ;;
		esac
		;;
	*)
		case "$pr_number" in
		200 | 203) printf '.agents/scripts/review-hook.sh\n+ add event payload guard before dispatch\n' ;;
		201) printf '.agents/scripts/review-hook.sh\n+ rename log_context to context_label\n' ;;
		*) printf '' ;;
		esac
		;;
	esac
	exit 0
fi

if [[ "${1:-}" == "issue" ]]; then
	log_call "$*"
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

run_validator_case() {
	local scenario="$1"
	local expected_rc="$2"
	local test_name="$3"
	local output_file="${TEST_ROOT}/${scenario}.out"
	local rc=0

	: >"$GH_LOG"
	export STUB_SCENARIO="$scenario"
	"$HELPER_SCRIPT" validate "100" "owner/repo" >"$output_file" 2>&1 || rc=$?

	if [[ "$rc" -eq "$expected_rc" ]]; then
		print_result "${test_name}: exit ${expected_rc}" 0
	else
		print_result "${test_name}: exit ${expected_rc}" 1 "got ${rc}; output=$(tr '\n' ' ' <"$output_file")"
	fi
	return 0
}

assert_log_contains() {
	local test_name="$1"
	local expected="$2"

	if grep -qF "$expected" "$GH_LOG"; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "missing log entry: ${expected}"
	fi
	return 0
}

assert_log_not_contains() {
	local test_name="$1"
	local unexpected="$2"

	if grep -qF "$unexpected" "$GH_LOG"; then
		print_result "$test_name" 1 "unexpected log entry: ${unexpected}"
	else
		print_result "$test_name" 0
	fi
	return 0
}

test_clear_same_file_fix() {
	run_validator_case "clear" 10 "clear same-file supersession"
	assert_log_contains "clear same-file supersession closes issue" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_ambiguous_same_file_unrelated_change() {
	run_validator_case "ambiguous" 0 "ambiguous same-file unrelated change"
	assert_log_not_contains "ambiguous same-file change does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_contains "ambiguous same-file change posts decision comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_source_pr_window_catches_pre_issue_fix() {
	run_validator_case "source-clear" 10 "source PR window catches pre-issue supersession"
	assert_log_contains "source PR window closes pre-issue supersession" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_malformed_source_pr_uses_title_fallback() {
	run_validator_case "malformed-source-clear" 10 "malformed source PR uses title fallback"
	assert_log_contains "malformed source PR title fallback closes pre-issue supersession" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_source_pr_window_ambiguous_fails_open() {
	run_validator_case "source-ambiguous" 0 "source PR window ambiguous same-file change"
	assert_log_not_contains "source PR ambiguous change does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_contains "source PR ambiguous change posts decision comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_source_pr_fetch_failure_falls_back() {
	run_validator_case "source-fetch-failure" 0 "source PR fetch failure falls back"
	assert_log_not_contains "source PR fetch failure does not use pre-issue candidate" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_no_file_finding_skips_supersession() {
	run_validator_case "no-file" 0 "no cited file paths skips supersession"
	assert_log_not_contains "no-file finding does not close" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

test_no_matching_pr() {
	run_validator_case "none" 0 "no matching merged PR"
	assert_log_not_contains "no matching PR does not close" "issue close 100 --repo owner/repo --reason not planned"
	assert_log_not_contains "no matching PR does not comment" "issue comment 100 --repo owner/repo --body"
	return 0
}

test_merged_pr_before_issue_creation() {
	run_validator_case "before" 0 "merged PR before issue creation"
	assert_log_not_contains "pre-issue merged PR does not close" "issue close 100 --repo owner/repo --reason not planned"
	return 0
}

main() {
	printf 'Running review-feedback supersession validator tests (t3569, GH#23101)...\n\n'

	if [[ ! -x "$HELPER_SCRIPT" ]]; then
		printf 'ERROR: helper script not executable: %s\n' "$HELPER_SCRIPT" >&2
		exit 1
	fi

	setup_test_env
	write_gh_stub
	test_clear_same_file_fix
	test_ambiguous_same_file_unrelated_change
	test_source_pr_window_catches_pre_issue_fix
	test_malformed_source_pr_uses_title_fallback
	test_source_pr_window_ambiguous_fails_open
	test_source_pr_fetch_failure_falls_back
	test_no_file_finding_skips_supersession
	test_no_matching_pr
	test_merged_pr_before_issue_creation
	teardown_test_env

	printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
