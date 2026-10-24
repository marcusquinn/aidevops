#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by release-lane-helper.sh; no scheduler or publication authority.

_AIDEVOPS_RELEASE_EXECUTOR_DEAD="dead"
_AIDEVOPS_RELEASE_ABANDONED_RECEIPT="abandoned-prepublication"

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

release_lane_liveness_report() {
	local state_json="$1"
	local observation=""
	local source_pr=""
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
			printf 'Recover without publication: aidevops release recover-reservation %s\n' "$source_pr"
		elif _release_lane_untouched_reservation "$state_json" &&
			[[ "$(jq -r '.state' <<<"$observation")" == "$_AIDEVOPS_RELEASE_EXECUTOR_DEAD" ]]; then
			printf 'Dead executor: wait until the configured recovery grace (at least 300 seconds) has elapsed since %s, then run: aidevops release recover-reservation %s\n' \
				"$(jq -r '.updated_at' <<<"$state_json")" "$source_pr"
		else
			printf 'Inspect the existing release owner; retrying patch or tag-based reconcile cannot resume this reservation.\n'
			printf 'Live, legacy, foreign, or recovery ownership cannot be automatically released; unknown is not an active executor.\n'
		fi
	elif jq -e '.active == true and .phase == "preparing" and .tag == null' <<<"$state_json" >/dev/null &&
		[[ "$(jq -r '.state' <<<"$observation")" == "$_AIDEVOPS_RELEASE_EXECUTOR_DEAD" ]]; then
		printf 'Preparing owner is dead before a tag was recorded. Rerun the exact authorized release command; fenced recovery will first verify the isolated worktree, source authorization, and every publication channel.\n'
	else
		printf 'Inspect/resume publication: aidevops release reconcile %s\n' "$source_pr"
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
