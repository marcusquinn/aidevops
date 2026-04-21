#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for `_nmr_application_has_automation_signature` and
# `_nmr_application_is_circuit_breaker_trip` in pulse-nmr-approval.sh
# (GH#18671 / t2386).
#
# t2386 background: `_nmr_application_has_automation_signature` used to
# match BOTH creation-time defaults (source:review-scanner) AND
# circuit-breaker trip markers (stale-recovery-tick:escalated,
# cost-circuit-breaker:fired). That conflation meant
# `auto_approve_maintainer_issues` stripped NMR from breaker-tripped
# issues and re-dispatched the worker, producing the #19756 infinite
# loop (22 watchdog kills, 5 auto-approve cycles in one afternoon).
#
# Post-fix semantics:
#   - _nmr_application_has_automation_signature  →  matches ONLY
#     creation defaults (source:review-scanner marker/label,
#     review-followup label). These can be auto-cleared.
#   - _nmr_application_is_circuit_breaker_trip   →  matches ONLY
#     breaker trips (stale-recovery-tick:escalated,
#     cost-circuit-breaker:fired, circuit-breaker-escalated). These
#     MUST preserve NMR.

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
	TIMELINE_FIXTURE="${TEST_ROOT}/timeline.json"
	export COMMENTS_FIXTURE ISSUE_META_FIXTURE TIMELINE_FIXTURE

	# gh stub: serves comments from COMMENTS_FIXTURE, issue meta from
	# ISSUE_META_FIXTURE, and timeline events from TIMELINE_FIXTURE.
	# Handles the --jq filter by piping into real jq.
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
	if [[ "$path" == */timeline ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$TIMELINE_FIXTURE" 2>/dev/null || echo ""
		else
			cat "$TIMELINE_FIXTURE"
		fi
		exit 0
	fi
	if [[ "$path" == */comments ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$COMMENTS_FIXTURE" 2>/dev/null || echo "0"
		else
			cat "$COMMENTS_FIXTURE"
		fi
		exit 0
	fi
	# repos/OWNER/REPO/issues/NUM (no /comments or /timeline suffix) — issue meta
	if [[ "$path" == */issues/* ]]; then
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
	printf '[]\n' >"$TIMELINE_FIXTURE"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

set_comments() {
	local body="$1"
	printf '%s\n' "$body" >"$COMMENTS_FIXTURE"
}
set_issue_meta() {
	local body="$1"
	printf '%s\n' "$body" >"$ISSUE_META_FIXTURE"
}
set_timeline() {
	local body="$1"
	printf '%s\n' "$body" >"$TIMELINE_FIXTURE"
}

# Extract all three helpers from the source file. Same awk-extract-and-eval
# pattern used by the force-dispatch and bot-cleanup test suites.
define_helpers_under_test() {
	local sig_src breaker_src maint_src
	sig_src=$(awk '
		/^_nmr_application_has_automation_signature\(\) \{/,/^}$/ { print }
	' "$NMR_SCRIPT")
	breaker_src=$(awk '
		/^_nmr_application_is_circuit_breaker_trip\(\) \{/,/^}$/ { print }
	' "$NMR_SCRIPT")
	maint_src=$(awk '
		/^_nmr_applied_by_maintainer\(\) \{/,/^}$/ { print }
	' "$NMR_SCRIPT")
	if [[ -z "$sig_src" || -z "$breaker_src" || -z "$maint_src" ]]; then
		printf 'ERROR: could not extract one of the NMR helpers from %s\n' "$NMR_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$sig_src"
	# shellcheck disable=SC1090
	eval "$breaker_src"
	# shellcheck disable=SC1090
	eval "$maint_src"
	return 0
}

# --- _nmr_application_has_automation_signature (creation defaults only) ---

test_signature_rejects_stale_recovery_marker() {
	# t2386: stale-recovery-tick:escalated is a BREAKER TRIP, not a
	# creation default. The signature function must return 1 so NMR is
	# preserved. Pre-t2386 this test asserted return 0 (the bug).
	set_comments '[{"created_at":"2026-04-13T05:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached** (t2008)"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18623 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature REJECTS stale-recovery:escalated marker (t2386)" 1 \
			"Expected exit 1 — breaker trip is not a creation-default signature"
		return 0
	fi
	print_result "signature REJECTS stale-recovery:escalated marker (t2386)" 0
	return 0
}

test_signature_rejects_cost_circuit_breaker_marker() {
	# t2386: same rationale as stale-recovery — breaker trip, not default.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- cost-circuit-breaker:fired tier=standard spent=120000 budget=100000 -->\n🛑 Cost circuit breaker fired"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18640 marcusquinn/aidevops "2026-04-13T05:00:02Z"; then
		print_result "signature REJECTS cost-circuit-breaker:fired marker (t2386)" 1 \
			"Expected exit 1 — breaker trip is not a creation-default signature"
		return 0
	fi
	print_result "signature REJECTS cost-circuit-breaker:fired marker (t2386)" 0
	return 0
}

test_signature_rejects_circuit_breaker_escalated_marker() {
	# t2386: legacy fast-fail alias — also a breaker trip.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- circuit-breaker-escalated -->"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18641 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature REJECTS circuit-breaker-escalated marker (t2386)" 1 \
			"Expected exit 1 — breaker trip is not a creation-default signature"
		return 0
	fi
	print_result "signature REJECTS circuit-breaker-escalated marker (t2386)" 0
	return 0
}

test_signature_detects_source_review_scanner_comment_marker() {
	# The one comment marker that IS a creation default — scanner
	# posted this at issue creation, applying NMR by default.
	set_comments '[{"created_at":"2026-04-13T05:00:02Z","body":"<!-- source:review-scanner -->\nPost-merge review scan flagged potential regressions."}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18622 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature detects source:review-scanner comment marker" 0
		return 0
	fi
	print_result "signature detects source:review-scanner comment marker" 1 \
		"Expected exit 0 — creation-default marker within window"
	return 0
}

test_signature_ignores_marker_outside_window() {
	# Comment 5 minutes after label event — outside the 60s window.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- source:review-scanner -->"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18623 marcusquinn/aidevops "2026-04-13T05:05:00Z"; then
		print_result "signature ignores creation-default marker outside 60s window" 1 \
			"Expected exit 1 — comment is 5 minutes before label event"
		return 0
	fi
	print_result "signature ignores creation-default marker outside 60s window" 0
	return 0
}

test_signature_detects_review_followup_label_fallback() {
	# No adjacent comment — but the issue has review-followup label,
	# indicating bot-generated cleanup (GH#18538 default-NMR path).
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"review-followup"},{"name":"auto-dispatch"}]}'
	if _nmr_application_has_automation_signature 18539 marcusquinn/aidevops "2026-04-13T04:29:13Z"; then
		print_result "signature detects review-followup label as implicit default" 0
		return 0
	fi
	print_result "signature detects review-followup label as implicit default" 1
	return 0
}

test_signature_detects_source_review_scanner_label_fallback() {
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"source:review-scanner"}]}'
	if _nmr_application_has_automation_signature 18621 marcusquinn/aidevops "2026-04-13T06:39:22Z"; then
		print_result "signature detects source:review-scanner label as implicit default" 0
		return 0
	fi
	print_result "signature detects source:review-scanner label as implicit default" 1
	return 0
}

test_signature_detects_source_review_feedback_label_fallback() {
	# t2686: quality-feedback-helper.sh emits source:review-feedback label,
	# NOT source:review-scanner. Before the fix the sig detector missed
	# this label entirely, stranding 10 issues on awardsapp/awardsapp.
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"quality-debt"},{"name":"source:review-feedback"},{"name":"priority:high"}]}'
	if _nmr_application_has_automation_signature 2572 awardsapp/awardsapp "2026-04-21T01:49:36Z"; then
		print_result "signature detects source:review-feedback label (t2686)" 0
		return 0
	fi
	print_result "signature detects source:review-feedback label (t2686)" 1 \
		"Expected exit 0 — source:review-feedback is a creation-default signature"
	return 0
}

test_signature_detects_quality_feedback_helper_comment_marker() {
	# t2686: the approval-instructions comment body contains the literal
	# string "quality-feedback-helper.sh" — defence-in-depth marker for
	# cases where the provenance label is stripped but the comment remains.
	# shellcheck disable=SC2016  # intentional: single quotes protect JSON literal with backticks
	set_comments '[{"created_at":"2026-04-21T01:49:38Z","body":"<!-- provenance:start — workers: skip this comment, it is for the maintainer not the implementer -->\nThis quality-debt issue was auto-generated by `quality-feedback-helper.sh scan-merged` from review feedback on PR #2391."}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 awardsapp/awardsapp "2026-04-21T01:49:36Z"; then
		print_result "signature detects quality-feedback-helper.sh comment marker (t2686)" 0
		return 0
	fi
	print_result "signature detects quality-feedback-helper.sh comment marker (t2686)" 1 \
		"Expected exit 0 — approval-instructions marker within window"
	return 0
}

test_signature_detects_source_review_feedback_comment_marker() {
	# t2686: comment body contains source:review-feedback literally
	# (future-proofing — in case quality-feedback-helper.sh ever emits
	# a standalone marker comment like post-merge-review-scanner.sh does).
	set_comments '[{"created_at":"2026-04-21T01:49:38Z","body":"<!-- source:review-feedback -->\nQuality-debt batch from merged PR."}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 awardsapp/awardsapp "2026-04-21T01:49:36Z"; then
		print_result "signature detects source:review-feedback comment marker (t2686)" 0
		return 0
	fi
	print_result "signature detects source:review-feedback comment marker (t2686)" 1
	return 0
}

test_signature_ignores_unrelated_comment_in_window() {
	# Comment is in the window but has no automation marker.
	set_comments '[{"created_at":"2026-04-13T05:00:30Z","body":"Thanks for the heads up, I will take a look at this tomorrow morning."}]'
	set_issue_meta '{"labels":[{"name":"bug"}]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature ignores unrelated comment in window" 1 \
			"Expected exit 1 — no creation-default marker in body"
		return 0
	fi
	print_result "signature ignores unrelated comment in window" 0
	return 0
}

test_signature_detects_lower_bound_comment_before_label() {
	# Comment posted 3 seconds BEFORE the label event — within the -5s
	# lower bound. Covers the API-latency race where the comment goes
	# through faster than the label API call.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- source:review-scanner -->"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:03Z"; then
		print_result "signature detects creation-default 3s before label (lower bound)" 0
		return 0
	fi
	print_result "signature detects creation-default 3s before label (lower bound)" 1
	return 0
}

test_signature_empty_args_returns_nonzero() {
	set_comments '[]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature "" "" ""; then
		print_result "signature empty args returns exit 1" 1
		return 0
	fi
	print_result "signature empty args returns exit 1" 0
	return 0
}

test_signature_no_default_no_bot_label_returns_nonzero() {
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"bug"},{"name":"auto-dispatch"}]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature returns exit 1 on normal bug issue" 1
		return 0
	fi
	print_result "signature returns exit 1 on normal bug issue" 0
	return 0
}

# --- _nmr_application_is_circuit_breaker_trip (breaker trips only) ---

test_breaker_trip_detects_stale_recovery_escalation_marker() {
	# t2386: breaker-trip helper DOES match this — and the caller
	# routes it to "preserve NMR".
	set_comments '[{"created_at":"2026-04-13T05:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached** (t2008)"}]'
	if _nmr_application_is_circuit_breaker_trip 18623 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "breaker_trip detects stale-recovery:escalated marker" 0
		return 0
	fi
	print_result "breaker_trip detects stale-recovery:escalated marker" 1 \
		"Expected exit 0 — stale-recovery marker within window"
	return 0
}

test_breaker_trip_detects_cost_circuit_breaker_marker() {
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- cost-circuit-breaker:fired tier=standard spent=120000 budget=100000 -->\n🛑 Cost circuit breaker fired"}]'
	if _nmr_application_is_circuit_breaker_trip 18640 marcusquinn/aidevops "2026-04-13T05:00:02Z"; then
		print_result "breaker_trip detects cost-circuit-breaker:fired marker" 0
		return 0
	fi
	print_result "breaker_trip detects cost-circuit-breaker:fired marker" 1
	return 0
}

test_breaker_trip_detects_legacy_escalated_marker() {
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- circuit-breaker-escalated -->"}]'
	if _nmr_application_is_circuit_breaker_trip 18641 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "breaker_trip detects circuit-breaker-escalated legacy alias" 0
		return 0
	fi
	print_result "breaker_trip detects circuit-breaker-escalated legacy alias" 1
	return 0
}

test_breaker_trip_rejects_source_review_scanner_marker() {
	# Creation-default marker is NOT a breaker trip.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- source:review-scanner -->"}]'
	if _nmr_application_is_circuit_breaker_trip 18621 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "breaker_trip REJECTS source:review-scanner marker" 1 \
			"Expected exit 1 — creation default is not a breaker trip"
		return 0
	fi
	print_result "breaker_trip REJECTS source:review-scanner marker" 0
	return 0
}

test_breaker_trip_ignores_marker_outside_window() {
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- stale-recovery-tick:escalated -->"}]'
	if _nmr_application_is_circuit_breaker_trip 42 marcusquinn/aidevops "2026-04-13T05:05:00Z"; then
		print_result "breaker_trip ignores marker outside 60s window" 1 \
			"Expected exit 1 — comment is 5 minutes before label event"
		return 0
	fi
	print_result "breaker_trip ignores marker outside 60s window" 0
	return 0
}

test_breaker_trip_empty_args_returns_nonzero() {
	set_comments '[]'
	if _nmr_application_is_circuit_breaker_trip "" "" ""; then
		print_result "breaker_trip empty args returns exit 1" 1
		return 0
	fi
	print_result "breaker_trip empty args returns exit 1" 0
	return 0
}

# --- _nmr_applied_by_maintainer end-to-end (#19756 loop regression) ---

test_19756_loop_prevention_breaker_trip_preserves_nmr() {
	# The #19756 scenario: pulse applies NMR via stale-recovery breaker.
	# Timeline actor is the maintainer (pulse runs as maintainer token).
	# Without the t2386 fix, _nmr_applied_by_maintainer returned 1
	# (automation-applied → auto-approve OK), and auto_approve stripped
	# NMR + re-dispatched, producing the infinite loop. Post-fix:
	# breaker-trip signature routes to return 0 (preserve NMR).
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-19T05:00:00Z"}]'
	set_comments '[{"created_at":"2026-04-19T05:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached** (t2008)"}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"}]}'
	if _nmr_applied_by_maintainer 19756 marcusquinn/aidevops marcusquinn; then
		print_result "t2386 #19756 loop prevention: breaker trip preserves NMR" 0
		return 0
	fi
	print_result "t2386 #19756 loop prevention: breaker trip preserves NMR" 1 \
		"Expected exit 0 — circuit breaker trip MUST preserve NMR (auto-approve loop bug)"
	return 0
}

test_scanner_default_still_auto_approves() {
	# Positive control: creation defaults still get auto-approved so
	# scanner-filed issues can enter dispatch normally.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-19T05:00:00Z"}]'
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"source:review-scanner"}]}'
	if _nmr_applied_by_maintainer 18539 marcusquinn/aidevops marcusquinn; then
		print_result "scanner-default issue still auto-approves (no regression)" 1 \
			"Expected exit 1 — creation-default signature should allow auto-approve"
		return 0
	fi
	print_result "scanner-default issue still auto-approves (no regression)" 0
	return 0
}

test_manual_hold_still_preserves_nmr() {
	# No signature of any kind — genuine manual hold. Must preserve NMR.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-19T05:00:00Z"}]'
	set_comments '[{"created_at":"2026-04-19T05:00:30Z","body":"Holding this pending architecture discussion."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"bug"}]}'
	if _nmr_applied_by_maintainer 42 marcusquinn/aidevops marcusquinn; then
		print_result "manual maintainer hold still preserves NMR" 0
		return 0
	fi
	print_result "manual maintainer hold still preserves NMR" 1 \
		"Expected exit 0 — no automation signature, this is a manual hold"
	return 0
}

test_non_maintainer_actor_auto_approves() {
	# Someone other than the maintainer applied NMR → not a manual hold
	# by the maintainer, so auto-approve is OK (return 1).
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"external-contributor"},"created_at":"2026-04-19T05:00:00Z"}]'
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"}]}'
	if _nmr_applied_by_maintainer 99 marcusquinn/aidevops marcusquinn; then
		print_result "non-maintainer actor → auto-approve OK" 1 \
			"Expected exit 1 — non-maintainer actor is not a manual hold"
		return 0
	fi
	print_result "non-maintainer actor → auto-approve OK" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	# _nmr_application_has_automation_signature (creation defaults only)
	test_signature_rejects_stale_recovery_marker
	test_signature_rejects_cost_circuit_breaker_marker
	test_signature_rejects_circuit_breaker_escalated_marker
	test_signature_detects_source_review_scanner_comment_marker
	test_signature_ignores_marker_outside_window
	test_signature_detects_review_followup_label_fallback
	test_signature_detects_source_review_scanner_label_fallback
	test_signature_detects_source_review_feedback_label_fallback
	test_signature_detects_quality_feedback_helper_comment_marker
	test_signature_detects_source_review_feedback_comment_marker
	test_signature_ignores_unrelated_comment_in_window
	test_signature_detects_lower_bound_comment_before_label
	test_signature_empty_args_returns_nonzero
	test_signature_no_default_no_bot_label_returns_nonzero

	# _nmr_application_is_circuit_breaker_trip (breaker trips only)
	test_breaker_trip_detects_stale_recovery_escalation_marker
	test_breaker_trip_detects_cost_circuit_breaker_marker
	test_breaker_trip_detects_legacy_escalated_marker
	test_breaker_trip_rejects_source_review_scanner_marker
	test_breaker_trip_ignores_marker_outside_window
	test_breaker_trip_empty_args_returns_nonzero

	# _nmr_applied_by_maintainer end-to-end (#19756 loop regression)
	test_19756_loop_prevention_breaker_trip_preserves_nmr
	test_scanner_default_still_auto_approves
	test_manual_hold_still_preserves_nmr
	test_non_maintainer_actor_auto_approves

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
