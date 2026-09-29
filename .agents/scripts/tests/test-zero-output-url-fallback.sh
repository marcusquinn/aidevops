#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '     %s\n' "$2"
	return 0
}

TMP=$(mktemp -d -t zero-output-url-fallback.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
FAST_FAIL_STATE_FILE="${TMP}/fast-fail-counter.json"
export LOGFILE FAST_FAIL_STATE_FILE

gh() {
	local command_name="${1:-}"
	shift || true
	local subcommand_name="${1:-}"
	if [[ "$command_name" == "api" ]]; then
		printf '%s\n' "$command_name $*" >>"${TMP}/gh-api-calls.log"
	fi
	if [[ "$command_name" == "api" && "$*" == *"--slurp"* && -n "${GH_RAW_COMMENTS:-}" ]]; then
		printf '%s\n' "$GH_RAW_COMMENTS"
		return 0
	fi
	if [[ "$command_name" == "api" && "$*" == *"--slurp"* ]]; then
		# The real API returns comment pages, not precomputed TSV metrics.
		local comments=0 ops=0 zero=0 chars=0
		IFS=$'\t' read -r comments ops zero chars <<<"${GH_COMMENT_METRICS:-$'0\t0\t0\t0'}"
		jq -nc --argjson comments "$comments" --argjson ops "$ops" --argjson zero "$zero" '
			[[range([$comments, $ops, $zero] | max) | . as $index |
			{body: ((if $index < $ops then "<!-- ops:start --> " else "" end) +
			(if $index < $zero then "worker_noop_zero_output" else "status" end)),
			author_association:"OWNER", user:{login:"runner"}}]]'
		return 0
	fi
	if [[ "$command_name" == "api" && "${GH_COMMENT_ZERO_COUNT:-0}" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$GH_COMMENT_ZERO_COUNT"
		return 0
	fi
	if [[ "$command_name" == "issue" && "$subcommand_name" == "view" && -n "${GH_ISSUE_BODY:-}" ]]; then
		printf '%s\n' "$GH_ISSUE_BODY"
		return 0
	fi
	printf '%s\n' "$command_name $*" >>"${TMP}/gh-calls.log"
	return 0
}
export -f gh

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh" >/dev/null 2>&1 || {
	printf 'FATAL Could not source pulse-dispatch-worker-launch.sh\n'
	exit 1
}

# Capture semantic lifecycle transitions after the sourced modules have loaded
# the production wrapper implementation.
set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status="$3"
	shift 3
	printf 'set_issue_status %s %s %s %s\n' "$issue_number" "$repo_slug" "$status" "$*" >>"${TMP}/gh-calls.log"
	return 0
}

write_state() {
	local count="$1"
	local reason="${2:-worker_noop_zero_output}"
	local crash_type="${3:-}"
	printf '{"owner/repo/123":{"count":%s,"ts":1,"reason":"%s","retry_after":0,"backoff_secs":600,"crash_type":"%s"}}\n' \
		"$count" "$reason" "$crash_type" >"$FAST_FAIL_STATE_FILE"
	return 0
}

write_state 2
GH_COMMENT_METRICS=""
ISSUE_BODY_SNAPSHOT_HELPER="/usr/bin/true"
export ISSUE_BODY_SNAPSHOT_HELPER
fallback_prompt=$(_dlw_prepare_prompt_for_launch 123 owner/repo "Test issue" "FULL EMBEDDED BRIEF")
if printf '%s' "$fallback_prompt" | grep -q 'gh issue view 123 --repo owner/repo --json body --jq' \
	&& printf '%s' "$fallback_prompt" | grep -q 'issue-body-snapshot-helper.sh fetch owner/repo 123' \
	&& ! printf '%s' "$fallback_prompt" | grep -q 'FULL EMBEDDED BRIEF'; then
	pass "repeated zero-output launches switch to URL-only bootstrap prompt"
else
	fail "repeated zero-output launches switch to URL-only bootstrap prompt" "$fallback_prompt"
fi

ISSUE_BODY_SNAPSHOT_HELPER="/usr/bin/false"
fallback_without_snapshot=$(_dlw_prepare_prompt_for_launch 123 owner/repo "Test issue" "FULL EMBEDDED BRIEF")
if [[ "$fallback_without_snapshot" == *"implementation is not authorized"* ]] \
	&& [[ "$fallback_without_snapshot" != *"issue-body-snapshot-helper.sh fetch"* ]]; then
	pass "URL-only fallback refuses implementation when snapshot capture fails"
else
	fail "URL-only fallback refuses implementation when snapshot capture fails" "$fallback_without_snapshot"
fi
ISSUE_BODY_SNAPSHOT_HELPER="/usr/bin/true"

write_state 1
GH_COMMENT_ZERO_COUNT=0
GH_COMMENT_METRICS=""
normal_prompt=$(_dlw_prepare_prompt_for_launch 123 owner/repo "Test issue" "FULL EMBEDDED BRIEF")
# shellcheck disable=SC2016 # Markdown backticks are intentional literals.
if [[ "$normal_prompt" == *"FULL EMBEDDED BRIEF"* ]] \
	&& [[ "$normal_prompt" == *"First-pass completion contract"* ]] \
	&& [[ "$normal_prompt" == *"do not hand off while it is draft or has unpushed changes"* ]] \
	&& [[ "$normal_prompt" == *"Never poll those gates or bypass approval, review, CI, branch-protection, or security controls"* ]] \
	&& [[ "$normal_prompt" == *'routine tool discovery'* ]] \
	&& [[ "$normal_prompt" == *'command -v TOOL'* ]] \
	&& [[ "$normal_prompt" == *'Do not use file-reading tools to inspect `~/.bun/bin`, `~/.qlty/bin`, or `~/.local/bin`'* ]] \
	&& [[ "$normal_prompt" != *"continue on that PR through local and remote verification"* ]]; then
	pass "below fallback threshold keeps embedded prompt"
else
	fail "below fallback threshold keeps embedded prompt" "$normal_prompt"
fi

write_state 1
GH_COMMENT_ZERO_COUNT=2
GH_COMMENT_METRICS=$'0\t0\t2\t0'
comment_fallback_prompt=$(_dlw_prepare_prompt_for_launch 123 owner/repo "Test issue" "FULL EMBEDDED BRIEF")
if printf '%s' "$comment_fallback_prompt" | grep -q 'gh issue view 123 --repo owner/repo --json body --jq' \
	&& ! printf '%s' "$comment_fallback_prompt" | grep -q 'FULL EMBEDDED BRIEF'; then
	pass "comment evidence triggers URL-only fallback when state count is low"
else
	fail "comment evidence triggers URL-only fallback when state count is low" "$comment_fallback_prompt"
fi

: >"${TMP}/gh-api-calls.log"
write_state 1
GH_COMMENT_ZERO_COUNT=0
GH_COMMENT_METRICS=$'50\t0\t2\t1000'
shared_metrics_prompt=$(_dlw_prepare_prompt_for_launch 123 owner/repo "Test issue" "FULL EMBEDDED BRIEF")
prepare_api_calls=$(wc -l <"${TMP}/gh-api-calls.log" | tr -d '[:space:]')
if printf '%s' "$shared_metrics_prompt" | grep -q 'gh issue view 123 --repo owner/repo --json body --jq' \
	&& [[ "$prepare_api_calls" == "1" ]]; then
	pass "prepare prompt reuses comment bloat metrics for zero-output evidence"
else
	fail "prepare prompt reuses comment bloat metrics for zero-output evidence" \
		"prompt=${shared_metrics_prompt}; api_calls=${prepare_api_calls}"
fi

write_state 1
GH_COMMENT_ZERO_COUNT=0
GH_COMMENT_METRICS=$'275\t260\t87\t81500'
GH_ISSUE_BODY="Clean body only: change app notifications query usage."
cat >"${TMP}/snapshot-helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"body":"Clean body only: change app notifications query usage."}'
EOF
chmod +x "${TMP}/snapshot-helper"
ISSUE_BODY_SNAPSHOT_HELPER="${TMP}/snapshot-helper"
clean_room_prompt=$(_dlw_prepare_prompt_for_launch 123 owner/repo "Test issue" "FULL EMBEDDED BRIEF WITH COMMENTS")
if printf '%s' "$clean_room_prompt" | grep -q 'clean-room brief mode' \
	&& printf '%s' "$clean_room_prompt" | grep -q 'Clean body only' \
	&& ! printf '%s' "$clean_room_prompt" | grep -q 'FULL EMBEDDED BRIEF WITH COMMENTS'; then
	pass "comment-bloated issues switch to clean-room body-only prompt"
else
	fail "comment-bloated issues switch to clean-room body-only prompt" "$clean_room_prompt"
fi

GH_COMMENT_METRICS=""
GH_ISSUE_BODY=""

: >"${TMP}/gh-calls.log"
write_state 4
GH_COMMENT_ZERO_COUNT=0
GH_COMMENT_METRICS=""
_dlw_hold_repeated_zero_output 123 owner/repo
hold_rc=$?
gh_calls=$(tr '\n' ' ' <"${TMP}/gh-calls.log" 2>/dev/null || true)
if [[ "$hold_rc" -eq 0 ]] \
	&& printf '%s' "$gh_calls" | grep -q 'set_issue_status 123 owner/repo blocked' \
	&& printf '%s' "$gh_calls" | grep -q 'dispatch-infrastructure-failure' \
	&& ! printf '%s' "$gh_calls" | grep -q -- '--add-label needs-maintainer-review' \
	&& ! printf '%s' "$gh_calls" | grep -q 'needs-brief-rewrite'; then
	pass "continued zero-output launches apply structural infrastructure block"
else
	fail "continued zero-output launches apply structural infrastructure block" \
		"rc=${hold_rc}; gh_calls=${gh_calls}"
fi

: >"${TMP}/gh-calls.log"
write_state 1
GH_COMMENT_ZERO_COUNT=4
GH_COMMENT_METRICS=$'0\t0\t4\t0'
_dlw_hold_repeated_zero_output 123 owner/repo
comment_hold_rc=$?
comment_gh_calls=$(tr '\n' ' ' <"${TMP}/gh-calls.log" 2>/dev/null || true)
if [[ "$comment_hold_rc" -eq 0 ]] \
	&& printf '%s' "$comment_gh_calls" | grep -q 'set_issue_status 123 owner/repo blocked' \
	&& printf '%s' "$comment_gh_calls" | grep -q 'dispatch-infrastructure-failure' \
	&& ! printf '%s' "$comment_gh_calls" | grep -q -- '--add-label needs-maintainer-review' \
	&& ! printf '%s' "$comment_gh_calls" | grep -q 'needs-brief-rewrite'; then
	pass "comment evidence triggers infrastructure hold when state count is low"
else
	fail "comment evidence triggers infrastructure hold when state count is low" \
		"rc=${comment_hold_rc}; gh_calls=${comment_gh_calls}"
fi

: >"${TMP}/gh-api-calls.log"
: >"${TMP}/gh-calls.log"
write_state 1
GH_COMMENT_ZERO_COUNT=0
GH_COMMENT_METRICS=$'50\t0\t4\t1000'
_dlw_hold_repeated_zero_output 123 owner/repo
shared_metrics_hold_rc=$?
shared_metrics_hold_calls=$(tr '\n' ' ' <"${TMP}/gh-calls.log" 2>/dev/null || true)
hold_api_calls=$(wc -l <"${TMP}/gh-api-calls.log" | tr -d '[:space:]')
if [[ "$shared_metrics_hold_rc" -eq 0 ]] \
	&& printf '%s' "$shared_metrics_hold_calls" | grep -q 'set_issue_status 123 owner/repo blocked' \
	&& printf '%s' "$shared_metrics_hold_calls" | grep -q 'dispatch-infrastructure-failure' \
	&& ! printf '%s' "$shared_metrics_hold_calls" | grep -q -- '--add-label needs-maintainer-review' \
	&& ! printf '%s' "$shared_metrics_hold_calls" | grep -q 'needs-brief-rewrite' \
	&& [[ "$hold_api_calls" == "1" ]]; then
	pass "zero-output hold reuses comment bloat metrics for evidence count"
else
	fail "zero-output hold reuses comment bloat metrics for evidence count" \
		"rc=${shared_metrics_hold_rc}; gh_calls=${shared_metrics_hold_calls}; api_calls=${hold_api_calls}"
fi

: >"${TMP}/gh-calls.log"
write_state 4
GH_COMMENT_ZERO_COUNT=4
GH_COMMENT_METRICS=$'275\t260\t87\t81500'
_dlw_hold_repeated_zero_output 123 owner/repo
clean_room_hold_rc=$?
clean_room_gh_calls=$(tr '\n' ' ' <"${TMP}/gh-calls.log" 2>/dev/null || true)
if [[ "$clean_room_hold_rc" -eq 0 ]] \
	&& printf '%s' "$clean_room_gh_calls" | grep -q 'set_issue_status 123 owner/repo blocked' \
	&& ! printf '%s' "$clean_room_gh_calls" | grep -q 'needs-brief-rewrite'; then
	pass "comment-bloated issues retain the repeated zero-output hold"
else
	fail "comment-bloated issues retain the repeated zero-output hold" \
		"rc=${clean_room_hold_rc}; gh_calls=${clean_room_gh_calls}"
fi

write_state 4 runtime partial
GH_COMMENT_ZERO_COUNT=0
GH_COMMENT_METRICS=""
non_zero_count=$(_dlw_zero_output_failure_count 123 owner/repo)
if [[ "$non_zero_count" == "0" ]]; then
	pass "non-zero-output failure reasons do not trigger URL-only fallback"
else
	fail "non-zero-output failure reasons do not trigger URL-only fallback" \
		"count=${non_zero_count}"
fi

write_state 4 worker_dirty_work_preserved partial
GH_COMMENT_ZERO_COUNT=0
GH_COMMENT_METRICS=""
preserved_dirty_count=$(_dlw_zero_output_failure_count 123 owner/repo)
if [[ "$preserved_dirty_count" == "0" ]]; then
	pass "preserved dirty work does not trigger brief-rewrite zero-output count"
else
	fail "preserved dirty work does not trigger brief-rewrite zero-output count" \
		"count=${preserved_dirty_count}"
fi

# GH#32928: hold notices mention "zero-output" and must not count as evidence.
hold_notice='<!-- dispatch-infrastructure-failure -->\n## Dispatch infrastructure failure detected\n\nThis issue has accumulated 12 zero-output or zero-attempt worker failures.'
self_count_json=$(jq -nc --arg notice "$hold_notice" '[[
	{id:1, created_at:"2026-09-28T21:00:00Z", body:$notice, author_association:"MEMBER", user:{login:"runner"}},
	{id:2, created_at:"2026-09-28T22:00:00Z", body:$notice, author_association:"MEMBER", user:{login:"runner"}}
]]')
self_count_metrics=$(_dlw_comment_bloat_metrics_from_json "$self_count_json" 1790640000 120 \
	"$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" "$_DLW_ZERO_ATTEMPT_EVIDENCE_PATTERN")
IFS=$'\t' read -r _sc_comments _sc_ops self_count_zero _sc_chars self_count_attempt <<<"$self_count_metrics"
GH_RAW_COMMENTS="$self_count_json"
self_comment_count=$(_dlw_zero_output_comment_count 123 owner/repo)
if [[ "$self_count_zero" == "0" && "$self_count_attempt" == "0" && "$self_comment_count" == "0" ]]; then
	pass "infrastructure hold notices do not count as zero-output evidence"
else
	fail "infrastructure hold notices do not count as zero-output evidence" \
		"metrics=${self_count_metrics}; comment_count=${self_comment_count}"
fi

# GH#32928: evidence before the latest authoritative reset is ignored.
reset_json=$(jq -nc '[[
	{id:1, created_at:"2026-09-28T20:00:00Z", body:"CLAIM_RELEASED reason=worker_noop_zero_output", author_association:"MEMBER", user:{login:"runner"}},
	{id:2, created_at:"2026-09-28T20:10:00Z", body:"CLAIM_RELEASED reason=worker_noop_zero_output", author_association:"MEMBER", user:{login:"runner"}},
	{id:3, created_at:"2026-09-28T23:30:00Z", body:"Fixed upstream. <!-- dispatch-infrastructure-reset -->", author_association:"OWNER", user:{login:"maintainer"}},
	{id:4, created_at:"2026-09-28T23:40:00Z", body:"CLAIM_RELEASED reason=worker_noop_zero_output", author_association:"MEMBER", user:{login:"runner"}}
]]')
reset_metrics=$(_dlw_comment_bloat_metrics_from_json "$reset_json" 1790640000 120 \
	"$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" "$_DLW_ZERO_ATTEMPT_EVIDENCE_PATTERN")
IFS=$'\t' read -r _rs_comments _rs_ops reset_zero _rs_chars _rs_attempt <<<"$reset_metrics"
GH_RAW_COMMENTS="$reset_json"
reset_comment_count=$(_dlw_zero_output_comment_count 123 owner/repo)
if [[ "$reset_zero" == "1" && "$reset_comment_count" == "1" ]]; then
	pass "authoritative reset marker clears earlier zero-output evidence"
else
	fail "authoritative reset marker clears earlier zero-output evidence" \
		"metrics=${reset_metrics}; comment_count=${reset_comment_count}"
fi

# A reset marker from a non-authoritative commenter must not clear evidence.
untrusted_reset_json=$(printf '%s' "$reset_json" | jq -c '.[0][2].author_association = "NONE" | .')
untrusted_metrics=$(_dlw_comment_bloat_metrics_from_json "$untrusted_reset_json" 1790640000 120 \
	"$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" "$_DLW_ZERO_ATTEMPT_EVIDENCE_PATTERN")
IFS=$'\t' read -r _ur_comments _ur_ops untrusted_zero _ur_chars _ur_attempt <<<"$untrusted_metrics"
if [[ "$untrusted_zero" == "3" ]]; then
	pass "non-authoritative reset marker is ignored"
else
	fail "non-authoritative reset marker is ignored" "metrics=${untrusted_metrics}"
fi
GH_RAW_COMMENTS=""

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
