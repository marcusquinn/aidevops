#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _nmr_application_has_automation_signature() and the updated
# _nmr_applied_by_maintainer() (GH#18671 / Fix 6b).
#
# The pulse runs as the maintainer's GitHub token, so when the t2008
# stale-recovery or t2007 cost circuit breaker applies the NMR label,
# the timeline actor is the maintainer. The fix: pair the label event
# with an adjacent (±60s) comment containing an automation marker, OR
# detect bot-cleanup labels on the issue itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
NMR_SCRIPT="${SCRIPT_DIR}/../pulse-nmr-approval.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
COMMENTS_FIXTURE=""
ISSUE_META_FIXTURE=""

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
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	COMMENTS_FIXTURE="${TEST_ROOT}/comments.json"
	ISSUE_META_FIXTURE="${TEST_ROOT}/issue-meta.json"
	export COMMENTS_FIXTURE ISSUE_META_FIXTURE

	# gh stub: serves comments from COMMENTS_FIXTURE and issue meta from
	# ISSUE_META_FIXTURE. Handles the --jq filter by piping into real jq.
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
	path="${2:-}"
	jq_filter=""
	shift 2 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--paginate) shift ;;
			--jq) jq_filter="$2"; shift 2 ;;
			*) shift ;;
		esac
	done
	if [[ "$path" == */comments ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$COMMENTS_FIXTURE" 2>/dev/null || echo "0"
		else
			cat "$COMMENTS_FIXTURE"
		fi
		exit 0
	fi
	# repos/OWNER/REPO/issues/NUM (no /comments suffix) — issue meta
	if [[ "$path" == */issues/* && "$path" != */timeline ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$ISSUE_META_FIXTURE" 2>/dev/null || echo "0"
		else
			cat "$ISSUE_META_FIXTURE"
		fi
		exit 0
	fi
fi
printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
EOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Seed empty fixtures
	printf '[]\n' >"$COMMENTS_FIXTURE"
	printf '{"labels":[]}\n' >"$ISSUE_META_FIXTURE"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

set_comments() {
	printf '%s\n' "$1" >"$COMMENTS_FIXTURE"
}
set_issue_meta() {
	printf '%s\n' "$1" >"$ISSUE_META_FIXTURE"
}

# Extract the helper from the source file. Same awk-extract-and-eval
# pattern used by the force-dispatch and bot-cleanup test suites.
define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_nmr_application_has_automation_signature\(\) \{/,/^}$/ { print }
	' "$NMR_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _nmr_application_has_automation_signature from %s\n' "$NMR_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

# --- test cases --------------------------------------------------------

test_detects_stale_recovery_escalation_marker() {
	# Real-world ordering: label applied first (t=00:00), comment posted
	# 2s later (t=00:02) — matches dispatch-dedup-helper.sh:607-609 where
	# set_issue_status runs before gh issue comment.
	set_comments '[{"created_at":"2026-04-13T05:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached** (t2008)"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18623 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "detects stale-recovery:escalated marker within window" 0
		return 0
	fi
	print_result "detects stale-recovery:escalated marker within window" 1 \
		"Expected exit 0 — comment is 2s after label event"
	return 0
}

test_detects_cost_circuit_breaker_marker() {
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- cost-circuit-breaker:fired tier=standard spent=120000 budget=100000 -->\n🛑 Cost circuit breaker fired"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18640 marcusquinn/aidevops "2026-04-13T05:00:02Z"; then
		print_result "detects cost-circuit-breaker:fired marker" 0
		return 0
	fi
	print_result "detects cost-circuit-breaker:fired marker" 1
	return 0
}

test_ignores_marker_outside_window() {
	# Comment 5 minutes after label event — outside the 60s window.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- stale-recovery-tick:escalated -->"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18623 marcusquinn/aidevops "2026-04-13T05:05:00Z"; then
		print_result "ignores marker outside 60s window" 1 \
			"Expected exit 1 — comment is 5 minutes before label event"
		return 0
	fi
	print_result "ignores marker outside 60s window" 0
	return 0
}

test_detects_review_followup_label_as_signature() {
	# No adjacent comment — but the issue has review-followup label,
	# indicating bot-generated cleanup (GH#18538 default-NMR path).
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"review-followup"},{"name":"auto-dispatch"}]}'
	if _nmr_application_has_automation_signature 18539 marcusquinn/aidevops "2026-04-13T04:29:13Z"; then
		print_result "detects review-followup label as implicit automation signature" 0
		return 0
	fi
	print_result "detects review-followup label as implicit automation signature" 1
	return 0
}

test_detects_source_review_scanner_label_as_signature() {
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"source:review-scanner"}]}'
	if _nmr_application_has_automation_signature 18621 marcusquinn/aidevops "2026-04-13T06:39:22Z"; then
		print_result "detects source:review-scanner label as implicit signature" 0
		return 0
	fi
	print_result "detects source:review-scanner label as implicit signature" 1
	return 0
}

test_ignores_unrelated_comment_in_window() {
	# Comment is in the window but has no automation marker.
	set_comments '[{"created_at":"2026-04-13T05:00:30Z","body":"Thanks for the heads up, I will take a look at this tomorrow morning."}]'
	set_issue_meta '{"labels":[{"name":"bug"}]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "ignores unrelated maintainer comment in window" 1 \
			"Expected exit 1 — no automation marker in body"
		return 0
	fi
	print_result "ignores unrelated maintainer comment in window" 0
	return 0
}

test_detects_lower_bound_comment_before_label() {
	# Comment posted 3 seconds BEFORE the label event — within the -5s
	# lower bound. This covers the API-latency race where the comment
	# goes through faster than the label API call.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- stale-recovery-tick:escalated -->"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:03Z"; then
		print_result "detects marker 3s before label event (lower bound)" 0
		return 0
	fi
	print_result "detects marker 3s before label event (lower bound)" 1
	return 0
}

test_empty_args_returns_nonzero() {
	set_comments '[]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature "" "" ""; then
		print_result "empty args return exit 1" 1
		return 0
	fi
	print_result "empty args return exit 1" 0
	return 0
}

test_no_comments_no_labels_returns_nonzero() {
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"bug"},{"name":"auto-dispatch"}]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "no signature on normal bug issue returns exit 1" 1
		return 0
	fi
	print_result "no signature on normal bug issue returns exit 1" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_detects_stale_recovery_escalation_marker
	test_detects_cost_circuit_breaker_marker
	test_ignores_marker_outside_window
	test_detects_review_followup_label_as_signature
	test_detects_source_review_scanner_label_as_signature
	test_ignores_unrelated_comment_in_window
	test_detects_lower_bound_comment_before_label
	test_empty_args_returns_nonzero
	test_no_comments_no_labels_returns_nonzero

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
