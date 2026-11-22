#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by release-lane-helper.sh; no scheduler or publication authority.

_AIDEVOPS_RELEASE_EXECUTOR_DEAD="dead"
_AIDEVOPS_RELEASE_ABANDONED_RECEIPT="abandoned-prepublication"
# t18896: the release path never waits longer than this for the session bus.
_AIDEVOPS_RELEASE_NOTICE_TIMEOUT_SECONDS=5

_release_lane_executor_capture() {
	python3 -I "${_AIDEVOPS_RELEASE_LANE_LIB_DIR}/release-lane-owner.py" capture "$$"
	return $?
}

_release_lane_executor_observe() {
	local state_json="$1"
	local executor=""
	executor=$(jq -c '.executor // null' <<<"$state_json") || return 1
	python3 -I "${_AIDEVOPS_RELEASE_LANE_LIB_DIR}/release-lane-owner.py" observe <<<"$executor"
	return $?
}

#aidevops:trust-boundary
# t18896: owner_session is self-reported by the capturing process and is
# advisory only: it feeds the held-lane hint and session-bus notices. Never
# read it for ownership, recovery, reconcile, abandonment or publication; the
# executor host_id/pid/started_at observation stays the only liveness authority.
# Prints a JSON object, or null when no valid session ID is available. Never fails.
_release_lane_owner_session_capture() {
	local session_id="${AIDEVOPS_OPENCODE_SESSION_ID:-${OPENCODE_SESSION_ID:-}}"
	if [[ "$session_id" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
		printf '{"session_id":"%s","captured_at":"%s"}\n' "$session_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		return 0
	fi
	printf 'null\n'
	return 0
}

_release_lane_notices_enabled() {
	[[ "${AIDEVOPS_RELEASE_NOTICES:-true}" != "false" ]]
	return $?
}

# Run the session-bus CLI with a hard wall-clock bound, including on macOS.
_release_lane_session_bus() {
	local helper="${_AIDEVOPS_RELEASE_LANE_LIB_DIR}/session-bus-helper.sh"
	local timeout_cmd=""
	[[ -f "$helper" ]] || return 1
	timeout_cmd=$(command -v timeout || command -v gtimeout) || timeout_cmd=""
	if [[ -z "$timeout_cmd" ]]; then
		python3 -I -c '
import os, signal, subprocess, sys
process = subprocess.Popen(["bash", *sys.argv[2:]], stdin=subprocess.DEVNULL, start_new_session=True)
try:
    sys.exit(process.wait(timeout=int(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    sys.exit(124)
' "$_AIDEVOPS_RELEASE_NOTICE_TIMEOUT_SECONDS" "$helper" "$@"
		return $?
	fi
	# TERM one second before the budget, then KILL, so the total stays within it.
	"$timeout_cmd" -k 1 "$((_AIDEVOPS_RELEASE_NOTICE_TIMEOUT_SECONDS - 1))" bash "$helper" "$@" </dev/null
	return $?
}

# Owner session presence JSON on stdout. Exit 0 live, 3 not live, 1 unknown
# (bus unavailable, timeout, or any other failure).
_release_lane_owner_session_show() {
	local session_id="$1"
	local err_file="" shown="" rc=0 err=""
	err_file=$(mktemp) || return 1
	shown=$(_release_lane_session_bus show "$session_id" --json 2>"$err_file") || rc=$?
	err=$(<"$err_file") || err=""
	rm -f "$err_file"
	if [[ "$rc" -eq 0 ]]; then
		printf '%s\n' "$shown"
		return 0
	fi
	if [[ "$rc" -eq 1 && ("$err" == *"session is not running"* || "$err" == *"no live OpenCode session matches"*) ]]; then
		return 3
	fi
	return 1
}

# Held-lane hint: the owner session's handle, status and an ask command, or a
# not-live note. Prints nothing on any failure and always returns 0.
release_lane_owner_session_hint() {
	local state_json="$1"
	local session_id="" source_pr="" shown="" rc=0 row="" handle="" status="" last_activity=""
	local unknown="${_AIDEVOPS_RELEASE_LANE_UNKNOWN:-unknown}"
	_release_lane_notices_enabled || return 0
	session_id=$(jq -r '.owner_session.session_id // empty | strings' <<<"$state_json" 2>/dev/null) || return 0
	source_pr=$(jq -r '.source_pr // empty' <<<"$state_json" 2>/dev/null) || return 0
	[[ "$session_id" =~ ^[A-Za-z0-9_-]{1,128}$ && "$source_pr" =~ ^[0-9]+$ ]] || return 0
	shown=$(_release_lane_owner_session_show "$session_id") || rc=$?
	if [[ "$rc" -eq 3 ]]; then
		printf 'RELEASE_OWNER_SESSION session=%s state=not-live\n' "$session_id"
		printf 'The owner session is not live; rely on the executor liveness line and recovery command above.\n'
		return 0
	fi
	[[ "$rc" -eq 0 ]] || return 0
	row=$(jq -r --arg unknown "$unknown" '[(.handle // "" | tostring | gsub("[^A-Za-z0-9._:-]"; "")),
		(.status // $unknown | tostring | gsub("[^a-z-]"; "")),
		(if (.last_activity_epoch | type) == "number" then (.last_activity_epoch | floor | todate) else $unknown end)]
		| join("\u001f")' <<<"$shown" 2>/dev/null) || return 0
	IFS=$'\x1f' read -r handle status last_activity <<<"$row" || return 0
	[[ -n "$handle" ]] || handle="$session_id"
	printf 'RELEASE_OWNER_SESSION handle=%s status=%s last_activity=%s session=%s\n' \
		"$handle" "${status:-$unknown}" "${last_activity:-$unknown}" "$session_id"
	if [[ "$session_id" == "${AIDEVOPS_OPENCODE_SESSION_ID:-${OPENCODE_SESSION_ID:-}}" ]]; then
		printf 'The owner session is this session.\n'
	else
		printf 'Ask the owner session: aidevops sessions ask %s "Is your release lane for PR #%s still in progress?"\n' \
			"$handle" "$source_pr"
	fi
	return 0
}

# Best-effort session-bus notice for a lane event. Advisory: output is
# discarded, the exit code is ignored, and the caller's result is unchanged.
release_lane_notify() {
	local state_json="$1"
	local event="$2"
	local receipt="${3:-}"
	local executor_state="${4:-}"
	local recovery="${5:-}"
	local marker="${6:-}"
	local fields="" repo="" source_pr="" tag="" owner_session=""
	_release_lane_notices_enabled || return 0
	# A non-whitespace separator keeps empty fields (a pending tag) in place.
	fields=$(jq -r '[(.repository // "" | tostring), (.source_pr // "" | tostring), (.tag // "" | tostring),
		(.owner_session.session_id // "" | tostring)] | map(gsub("[\u0000-\u001f]"; "")) | join("\u001f")' \
		<<<"$state_json" 2>/dev/null) || return 0
	IFS=$'\x1f' read -r repo source_pr tag owner_session <<<"$fields" || return 0
	[[ -n "$repo" && "$source_pr" =~ ^[0-9]+$ ]] || return 0
	local -a args=(notify-release --repo "$repo" --source-pr "$source_pr" --event "$event")
	[[ -z "$tag" ]] || args+=(--tag "$tag")
	[[ -z "$receipt" ]] || args+=(--receipt "$receipt")
	[[ -z "$executor_state" ]] || args+=(--executor-state "$executor_state")
	[[ -z "$recovery" ]] || args+=(--recovery "$recovery")
	[[ -z "$owner_session" ]] || args+=(--owner-session "$owner_session")
	[[ -z "$marker" ]] || args+=(--marker "$marker")
	_release_lane_session_bus "${args[@]}" >/dev/null 2>&1 || true
	return 0
}

_release_lane_notice_event() {
	local receipt="$1"
	case "$receipt" in
	published | superseded) printf '%s\n' "$receipt" ;;
	*) printf 'failed\n' ;;
	esac
	return 0
}

# One notice per dead executor identity: the bus marker makes repeats no-ops.
_release_lane_notify_dead_executor() {
	local state_json="$1"
	local observation="$2"
	local recovery="$3"
	local marker="" reason=""
	_release_lane_notices_enabled || return 0
	marker=$(jq -r '[(.source_pr // ""), (.executor.host_id // ""), (.executor.pid // ""), (.executor.started_at // "")]
		| map(tostring) | join(":")' <<<"$state_json" 2>/dev/null) || return 0
	reason=$(jq -r '.reason // "dead" | tostring | gsub("[^a-z0-9-]"; "")' <<<"$observation" 2>/dev/null) || reason="dead"
	release_lane_notify "$state_json" executor-dead "" "${reason:-dead}" "$recovery" "$marker"
	return 0
}

release_lane_liveness_report() {
	local state_json="$1"
	local observation=""
	local source_pr=""
	local recovery=""
	if jq -e '.active == false' <<<"$state_json" >/dev/null; then
		printf 'RELEASE_EXECUTOR={"state":"not-required","reason":"inactive-lane"}\n'
		return 0
	fi
	observation=$(_release_lane_executor_observe "$state_json") || observation='{"state":"unknown","reason":"observation-unavailable"}'
	printf 'RELEASE_EXECUTOR=%s\n' "$observation"
	source_pr=$(jq -r '.source_pr' <<<"$state_json") || return 1
	if jq -e '.active == true and .phase == "reserved" and .tag == null' <<<"$state_json" >/dev/null; then
		printf 'Reservation has no recorded tag; tag-based reconcile alone may not resume it.\n'
		if _release_lane_abandoned_reservation "$state_json"; then
			recovery="aidevops release recover-reservation ${source_pr}"
			printf 'Recover without publication: aidevops release recover-reservation %s\n' "$source_pr"
		elif _release_lane_untouched_reservation "$state_json" &&
			[[ "$(jq -r '.state' <<<"$observation")" == "$_AIDEVOPS_RELEASE_EXECUTOR_DEAD" ]]; then
			recovery="aidevops release recover-reservation ${source_pr}"
			printf 'Dead executor: wait until the configured recovery grace (at least 300 seconds) has elapsed since %s, then run: aidevops release recover-reservation %s\n' \
				"$(jq -r '.updated_at' <<<"$state_json")" "$source_pr"
		else
			recovery="aidevops release status ${source_pr}"
			printf 'Inspect the existing release owner; retrying patch or tag-based reconcile cannot resume this reservation.\n'
			printf 'Live, legacy, foreign, or recovery ownership cannot be automatically released; unknown is not an active executor.\n'
		fi
	elif jq -e '.active == true and .phase == "preparing" and .tag == null' <<<"$state_json" >/dev/null &&
		[[ "$(jq -r '.state' <<<"$observation")" == "$_AIDEVOPS_RELEASE_EXECUTOR_DEAD" ]]; then
		recovery="aidevops release status ${source_pr}"
		printf 'Preparing owner is dead before a tag was recorded. Rerun the exact authorized release command; fenced recovery will first verify the isolated worktree, source authorization, and every publication channel.\n'
	else
		recovery="aidevops release reconcile ${source_pr}"
		printf 'Inspect/resume publication: aidevops release reconcile %s\n' "$source_pr"
	fi
	if jq -e '.active == true' <<<"$state_json" >/dev/null 2>&1 &&
		[[ "$(jq -r '.state' <<<"$observation" 2>/dev/null)" == "$_AIDEVOPS_RELEASE_EXECUTOR_DEAD" ]]; then
		_release_lane_notify_dead_executor "$state_json" "$observation" "$recovery"
	fi
	return 0
}

#aidevops:trust-boundary
# Only modern untouched reservations have the enforced preparing-before-publish
# contract. Never infer that contract for legacy, adopted or recovery state.
_release_lane_untouched_reservation() {
	local state_json="$1"
	jq -e '
        .active == true and .phase == "reserved" and .tag == null
        and .reservation_contract == "fenced-prepublication/v1"
        and .terminal_receipt == null and .prepublication_recovery == null
        and .aggregate_recovery == null and .aggregate_successor == null
        and .reserved_authorization_refresh == null
    ' <<<"$state_json" >/dev/null || return 1
	return 0
}

_release_lane_abandoned_reservation() {
	local state_json="$1"
	local observation=""
	local grace="${AIDEVOPS_RELEASE_LANE_STALE_SECONDS:-300}"
	[[ "$grace" =~ ^[0-9]+$ && ${#grace} -le 8 ]] || return 1
	[[ "$grace" -ge 300 ]] || grace=300
	_release_lane_untouched_reservation "$state_json" || return 1
	AIDEVOPS_RELEASE_LANE_STALE_SECONDS="$grace" _release_lane_stale_prepublication "$state_json" || return 1
	observation=$(_release_lane_executor_observe "$state_json") || return 1
	[[ "$(jq -r '.state' <<<"$observation")" == "$_AIDEVOPS_RELEASE_EXECUTOR_DEAD" ]]
	return $?
}

#aidevops:trust-boundary
# Only the exiting executor may skip the dead-owner grace, before preparing.
release_lane_abandon_owned_reservation() {
	local repo="$1"
	local source_pr="$2"
	local executor=""
	local snapshot=""
	local state_json=""
	[[ "$source_pr" =~ ^[0-9]+$ && -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	executor=$(_release_lane_executor_capture) || return 1
	jq -e '.host_id != null and .pid != null and .started_at != null' <<<"$executor" >/dev/null || return 1
	release_lane_read "$repo" || return 1
	snapshot="$_AIDEVOPS_RELEASE_LANE_HEAD"
	_release_lane_untouched_reservation "$_AIDEVOPS_RELEASE_LANE_JSON" || return 1
	jq -e --argjson pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --argjson executor "$executor" '
		.source_pr == $pr and .operation_token == $token and .executor == $executor
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	state_json=$(jq -c --arg snapshot "$snapshot" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--arg receipt "$_AIDEVOPS_RELEASE_ABANDONED_RECEIPT" '
		.active=false | .phase="terminal" | .terminal_receipt=$receipt
		| .updated_at=$now | .reservation_recovery={observed_head:$snapshot,reason:"owner-preparation-refused",at:$now}
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$snapshot" || return 1
	printf 'RELEASE_RESERVATION_RECOVERED source_pr=%s receipt=abandoned-prepublication reason=owner-preparation-refused\n' "$source_pr"
	return 0
}

#aidevops:trust-boundary
release_lane_recover_reservation() {
	local repo="$1"
	local source_pr="$2"
	local expected_head="${3:-}"
	local snapshot=""
	local permission=""
	local state_json=""
	[[ "$source_pr" =~ ^[0-9]+$ ]] || return 1
	release_lane_read "$repo" || return 1
	[[ -z "$expected_head" || "$expected_head" == "$_AIDEVOPS_RELEASE_LANE_HEAD" ]] || return 75
	snapshot="$_AIDEVOPS_RELEASE_LANE_HEAD"
	jq -e --argjson pr "$source_pr" '.source_pr == $pr' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 75
	if jq -e --arg receipt "$_AIDEVOPS_RELEASE_ABANDONED_RECEIPT" '.active == false and .terminal_receipt == $receipt' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
		return 0
	fi
	_release_lane_abandoned_reservation "$_AIDEVOPS_RELEASE_LANE_JSON" || {
		printf 'Reservation recovery refused: live, unknown, legacy, or possible publication state\n' >&2
		return 75
	}
	permission=$(gh api "repos/${repo}" --jq '.permissions.push == true or .permissions.maintain == true or .permissions.admin == true' 2>/dev/null) || return 1
	[[ "$permission" == "true" ]] || return 75
	state_json=$(jq -c --arg snapshot "$snapshot" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--arg receipt "$_AIDEVOPS_RELEASE_ABANDONED_RECEIPT" '
         .active=false | .phase="terminal" | .terminal_receipt=$receipt
        | .updated_at=$now | .reservation_recovery={observed_head:$snapshot,reason:"verified-dead-executor",at:$now}
    ' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	# A concurrent preparing/adoption write wins the CAS and refuses this unlock.
	_release_lane_write "$repo" "$state_json" "$snapshot" || return $?
	printf 'RELEASE_RESERVATION_RECOVERED source_pr=%s receipt=abandoned-prepublication\n' "$source_pr"
	return 0
}
