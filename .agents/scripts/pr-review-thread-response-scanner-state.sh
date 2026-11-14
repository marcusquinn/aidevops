#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pr-review-thread-response-scanner-state.sh - state/outcome persistence for
# the review-thread response scanner. Sourced by
# pr-review-thread-response-scanner.sh; not executable on its own.

# Include guard
[[ -n "${_PRRTS_STATE_LIB_LOADED:-}" ]] && return 0
_PRRTS_STATE_LIB_LOADED=1

_prrts_read_state() {
	local state_file="$1"
	local fingerprint_var="$2"
	local dispatched_var="$3"
	local attempt_var="${4:-}"
	local analysis_complete_var="${5:-}"
	local blocked_by_var="${6:-}"
	local maintainer_attention_var="${7:-}"
	local head_sha_var="${8:-}"
	local blocker_reason_var="${9:-}"
	local worker_contract_version_var="${10:-}"
	local outcome_id_var="${11:-}"
	local infrastructure_failure_count_var="${12:-}"
	local completed_var="${13:-}"
	local key="" value=""
	local state_fingerprint="" state_dispatched_at="0"
	local state_attempt_count="0"
	local state_last_head_sha=""
	local state_analysis_complete="$PRRTS_BOOL_FALSE" state_blocked_by="" state_maintainer_attention="$PRRTS_BOOL_FALSE"
	local state_blocker_reason="" state_worker_contract_version="" state_outcome_id=""
	local state_infrastructure_failure_count="0"
	local state_completed_at="0"
	if [[ -f "$state_file" ]]; then
		while IFS='=' read -r key value; do
			case "$key" in
			fingerprint) state_fingerprint="$value" ;;
			dispatched_at) state_dispatched_at="$value" ;;
			attempt_count) state_attempt_count="$value" ;;
			last_head_sha) state_last_head_sha="$value" ;;
			analysis_complete) state_analysis_complete="$value" ;;
			blocked_by) state_blocked_by="$value" ;;
			maintainer_attention) state_maintainer_attention="$value" ;;
			attention_reason) [[ -n "$state_blocker_reason" ]] || state_blocker_reason="$value" ;;
			blocker_reason) state_blocker_reason="$value" ;;
			worker_contract_version) state_worker_contract_version="$value" ;;
			outcome_id) state_outcome_id="$value" ;;
			infrastructure_failure_count) state_infrastructure_failure_count="$value" ;;
			completed_at) state_completed_at="$value" ;;
			esac
		done <"$state_file"
	fi
	[[ "$state_dispatched_at" =~ ^[0-9]+$ ]] || state_dispatched_at=0
	[[ "$state_attempt_count" =~ ^[0-9]+$ ]] || state_attempt_count=0
	[[ "$state_infrastructure_failure_count" =~ ^[0-9]+$ ]] || state_infrastructure_failure_count=0
	[[ "$state_completed_at" =~ ^[0-9]+$ ]] || state_completed_at=0
	[[ "$state_analysis_complete" == "$PRRTS_BOOL_TRUE" ]] || state_analysis_complete="$PRRTS_BOOL_FALSE"
	[[ "$state_maintainer_attention" == "$PRRTS_BOOL_TRUE" ]] || state_maintainer_attention="$PRRTS_BOOL_FALSE"
	printf -v "$fingerprint_var" '%s' "$state_fingerprint"
	printf -v "$dispatched_var" '%s' "$state_dispatched_at"
	if [[ -n "$attempt_var" ]]; then
		printf -v "$attempt_var" '%s' "$state_attempt_count"
	fi
	if [[ -n "$analysis_complete_var" ]]; then
		printf -v "$analysis_complete_var" '%s' "$state_analysis_complete"
	fi
	if [[ -n "$blocked_by_var" ]]; then
		printf -v "$blocked_by_var" '%s' "$state_blocked_by"
	fi
	if [[ -n "$maintainer_attention_var" ]]; then
		printf -v "$maintainer_attention_var" '%s' "$state_maintainer_attention"
	fi
	if [[ -n "$head_sha_var" ]]; then
		printf -v "$head_sha_var" '%s' "$state_last_head_sha"
	fi
	if [[ -n "$blocker_reason_var" ]]; then
		printf -v "$blocker_reason_var" '%s' "$state_blocker_reason"
	fi
	if [[ -n "$worker_contract_version_var" ]]; then
		printf -v "$worker_contract_version_var" '%s' "$state_worker_contract_version"
	fi
	if [[ -n "$outcome_id_var" ]]; then
		printf -v "$outcome_id_var" '%s' "$state_outcome_id"
	fi
	if [[ -n "$infrastructure_failure_count_var" ]]; then
		printf -v "$infrastructure_failure_count_var" '%s' "$state_infrastructure_failure_count"
	fi
	if [[ -n "$completed_var" ]]; then
		printf -v "$completed_var" '%s' "$state_completed_at"
	fi
	return 0
}

_prrts_read_outcome() {
	local outcome_file="$1"
	local reason_var="$2"
	local session_count_var="$3"
	local finished_at_var="$4"
	local outcome_id_var="$5"
	local retry_class_var="${6:-}"
	local key value
	local parsed_reason="" parsed_session_count="" parsed_finished_at="0" parsed_outcome_id="" parsed_retry_class=""
	if [[ -f "$outcome_file" ]]; then
		while IFS='=' read -r key value; do
			case "$key" in
			reason) parsed_reason="$value" ;;
			session_count) parsed_session_count="$value" ;;
			finished_at) parsed_finished_at="$value" ;;
			outcome_id) parsed_outcome_id="$value" ;;
			retry_class) parsed_retry_class="$value" ;;
			esac
		done <"$outcome_file"
	fi
	[[ "$parsed_session_count" =~ ^[0-9]+$ ]] || parsed_session_count=""
	[[ "$parsed_finished_at" =~ ^[0-9]+$ ]] || parsed_finished_at=0
	printf -v "$reason_var" '%s' "$parsed_reason"
	printf -v "$session_count_var" '%s' "$parsed_session_count"
	printf -v "$finished_at_var" '%s' "$parsed_finished_at"
	printf -v "$outcome_id_var" '%s' "$parsed_outcome_id"
	if [[ -n "$retry_class_var" ]]; then
		printf -v "$retry_class_var" '%s' "$parsed_retry_class"
	fi
	return 0
}

_prrts_write_infrastructure_outcome() {
	local repo_slug="$1"
	local pr_number="$2"
	local outcome_id="$3"
	local session_key="$4"
	local reason="$5"
	local outcome_file=""
	local outcome_tmp=""
	local finished_at=""
	[[ "$outcome_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
	[[ "$session_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$ ]] || return 1
	[[ "$reason" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$ ]] || reason="review_worker_launch_failed"
	_prrts_ensure_dirs
	outcome_file="$(_prrts_outcome_file "$repo_slug" "$pr_number")"
	[[ "$outcome_file" == "${STATE_DIR}/"*.outcome && ! -L "$outcome_file" ]] || return 1
	finished_at=$(date +%s)
	outcome_tmp="${outcome_file}.tmp.$$"
	if ! {
		printf 'session_key=%s\n' "$session_key"
		printf 'outcome_id=%s\n' "$outcome_id"
		printf 'reason=%s\n' "$reason"
		printf 'session_count=0\n'
		printf 'retry_class=%s\n' "$PRRTS_RETRY_CLASS_INFRASTRUCTURE"
		printf 'finished_at=%s\n' "$finished_at"
	} >"$outcome_tmp"; then
		rm -f "$outcome_tmp"
		return 1
	fi
	if ! mv -f "$outcome_tmp" "$outcome_file"; then
		rm -f "$outcome_tmp"
		return 1
	fi
	chmod 600 "$outcome_file" 2>/dev/null || true
	return 0
}

_prrts_outcome_matches_dispatch() {
	local expected_outcome_id="$1"
	local observed_outcome_id="$2"
	local outcome_reason="$3"
	local outcome_session_count="$4"
	local outcome_finished_at="$5"
	local dispatched_at="$6"
	local now_epoch="$7"
	local latest_allowed=""

	[[ -n "$expected_outcome_id" && "$observed_outcome_id" == "$expected_outcome_id" ]] || return 1
	[[ -n "$outcome_reason" && "$outcome_session_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$outcome_finished_at" =~ ^[0-9]{1,12}$ && "$dispatched_at" =~ ^[0-9]{1,12}$ && "$now_epoch" =~ ^[0-9]{1,12}$ ]] || return 1
	latest_allowed=$((now_epoch + 5))
	[[ "$outcome_finished_at" -ge "$dispatched_at" && "$outcome_finished_at" -le "$latest_allowed" ]]
	return $?
}

_prrts_is_zero_session_infrastructure_outcome() {
	local expected_outcome_id="$1"
	local observed_outcome_id="$2"
	local outcome_reason="$3"
	local outcome_session_count="$4"
	local outcome_finished_at="$5"
	local dispatched_at="$6"
	local now_epoch="$7"
	_prrts_outcome_matches_dispatch "$expected_outcome_id" "$observed_outcome_id" \
		"$outcome_reason" "$outcome_session_count" "$outcome_finished_at" "$dispatched_at" "$now_epoch" || return 1
	[[ "$outcome_reason" == "worker_noop_zero_output" && "$outcome_session_count" == "0" ]] || return 1
	return 0
}

_prrts_infrastructure_retry_status() {
	local repo_slug="$1"
	local pr_number="$2"
	local now_epoch="$3"
	local outcome_finished_at="$4"
	local short_cooldown="$5"
	local full_cooldown="$6"
	local failure_count="$7"
	local failure_max="$8"
	local outcome_reason="$9"
	local age_seconds=$((now_epoch - outcome_finished_at))

	[[ "$age_seconds" -ge 0 ]] || age_seconds=0
	if [[ "$outcome_reason" == "worker_noop_zero_output" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} worker_noop_zero_output session_count=0 — classifying as infrastructure failure"
	fi
	_prrts_log "dispatch: ${repo_slug}#${pr_number} outcome=${outcome_reason} retry_class=${PRRTS_RETRY_CLASS_INFRASTRUCTURE} — excluding it from remediation escalation"
	if [[ "$failure_count" -ge "$failure_max" ]]; then
		if [[ "$age_seconds" -lt "$full_cooldown" ]]; then
			_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — infrastructure circuit-breaker cooldown active after ${failure_count} consecutive failure(s)"
			return "$PRRTS_RC_DISPATCH_DEFERRED"
		fi
		_prrts_log "dispatch: ${repo_slug}#${pr_number} retrying after bounded infrastructure circuit-breaker cooldown"
		return 0
	fi
	if [[ "$age_seconds" -lt "$short_cooldown" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — infrastructure-failure short cooldown active ${age_seconds}s after terminal outcome"
		return "$PRRTS_RC_DISPATCH_DEFERRED"
	fi
	_prrts_log "dispatch: ${repo_slug}#${pr_number} retrying after infrastructure-failure short cooldown (${age_seconds}s)"
	return 0
}

_prrts_retryable_prelaunch_failure_once() {
	local blocker_reason="$1"
	case "$blocker_reason" in
	pr_head_branch_invalid | pr_head_sha_invalid | pr_head_branch_unavailable | "$PRRTS_REASON_HEAD_FETCH_FAILED")
		return 0
		;;
	*)
		return 1
		;;
	esac
}

_prrts_prelaunch_failure_needs_maintainer_attention() {
	local blocked_by="$1"
	[[ "$blocked_by" == "$PRRTS_BLOCKED_BY_CODE" ]]
	return $?
}

_prrts_classify_previous_dispatch() {
	local fingerprint="$1" last_fingerprint="$2" current_head_sha="$3" last_head_sha="$4"
	local last_attempt_count="$5" expected_outcome_id="$6" observed_outcome_id="$7" outcome_reason="$8"
	local outcome_session_count="$9" outcome_finished_at="${10}" dispatched_at="${11}" now_epoch="${12}"
	local outcome_retry_class="${13}" last_infrastructure_failure_count="${14}"
	local repeated_var="${15}" same_head_var="${16}" attempt_var="${17}"
	local infrastructure_var="${18}" maintainer_var="${19}" infrastructure_count_var="${20}"
	local repeated="$PRRTS_BOOL_FALSE" same_head="$PRRTS_BOOL_FALSE" attempt_count="1"
	local infrastructure="$PRRTS_BOOL_FALSE" maintainer="$PRRTS_BOOL_FALSE" infrastructure_count="0"
	if [[ -n "$last_fingerprint" && "$fingerprint" == "$last_fingerprint" ]]; then
		same_head="$PRRTS_BOOL_TRUE"
		if [[ -n "$last_head_sha" && -n "$current_head_sha" && "$current_head_sha" != "$last_head_sha" ]]; then
			same_head="$PRRTS_BOOL_FALSE"
		else
			repeated="$PRRTS_BOOL_TRUE"
			attempt_count=$((last_attempt_count + 1))
		fi
	fi
	if [[ "$repeated" == "$PRRTS_BOOL_TRUE" && "$same_head" == "$PRRTS_BOOL_TRUE" ]] &&
		_prrts_outcome_matches_dispatch "$expected_outcome_id" "$observed_outcome_id" \
			"$outcome_reason" "$outcome_session_count" "$outcome_finished_at" "$dispatched_at" "$now_epoch"; then
		if [[ "$outcome_retry_class" == "$PRRTS_RETRY_CLASS_INFRASTRUCTURE" ||
			("$outcome_reason" == "auth_error" && "$outcome_retry_class" == "$PRRTS_RETRY_CLASS_REMEDIATION") ]]; then
			infrastructure="$PRRTS_BOOL_TRUE"
		elif [[ "$outcome_retry_class" == "$PRRTS_RETRY_CLASS_MAINTAINER_GATE" ]]; then
			maintainer="$PRRTS_BOOL_TRUE"
		fi
	fi
	if [[ "$infrastructure" == "$PRRTS_BOOL_FALSE" && "$maintainer" == "$PRRTS_BOOL_FALSE" &&
		"$repeated" == "$PRRTS_BOOL_TRUE" && "$same_head" == "$PRRTS_BOOL_TRUE" ]] &&
		_prrts_is_zero_session_infrastructure_outcome "$expected_outcome_id" "$observed_outcome_id" \
			"$outcome_reason" "$outcome_session_count" "$outcome_finished_at" "$dispatched_at" "$now_epoch"; then
		infrastructure="$PRRTS_BOOL_TRUE"
	fi
	if [[ "$infrastructure" == "$PRRTS_BOOL_TRUE" || "$maintainer" == "$PRRTS_BOOL_TRUE" ]]; then
		attempt_count="$last_attempt_count"
		[[ "$attempt_count" -gt 0 ]] || attempt_count=1
	fi
	if [[ "$infrastructure" == "$PRRTS_BOOL_TRUE" ]]; then
		infrastructure_count=$((last_infrastructure_failure_count + 1))
	fi
	printf -v "$repeated_var" '%s' "$repeated"
	printf -v "$same_head_var" '%s' "$same_head"
	printf -v "$attempt_var" '%s' "$attempt_count"
	printf -v "$infrastructure_var" '%s' "$infrastructure"
	printf -v "$maintainer_var" '%s' "$maintainer"
	printf -v "$infrastructure_count_var" '%s' "$infrastructure_count"
	return 0
}

_prrts_set_dispatch_outputs() {
	local attempt_output_var="$1" attempt_value="$2" repeated_output_var="$3" repeated_value="$4"
	local same_head_output_var="$5" same_head_value="$6" infrastructure_output_var="$7" infrastructure_value="$8"
	if [[ -n "$attempt_output_var" ]]; then
		printf -v "$attempt_output_var" '%s' "$attempt_value"
	fi
	if [[ -n "$repeated_output_var" ]]; then
		printf -v "$repeated_output_var" '%s' "$repeated_value"
	fi
	if [[ -n "$same_head_output_var" ]]; then
		printf -v "$same_head_output_var" '%s' "$same_head_value"
	fi
	if [[ -n "$infrastructure_output_var" ]]; then
		printf -v "$infrastructure_output_var" '%s' "$infrastructure_value"
	fi
	return 0
}

# A progress record belongs only to the dispatch it completed, not a later one.
_prrts_has_fresh_progress() {
	local reason="$1" analysis_complete="$2" completed_at="$3" dispatched_at="$4"
	if [[ "$reason" == progress:* && "$analysis_complete" == "$PRRTS_BOOL_FALSE" && "$completed_at" -gt "$dispatched_at" ]]; then
		return 0
	fi
	return 1
}

_prrts_should_dispatch() {
	local repo_slug="$1"
	local pr_number="$2"
	local fingerprint="$3"
	local now_epoch="$4"
	local current_head_sha="$5"
	local attempt_var="${6:-}"
	local repeated_var="${7:-}"
	local same_head_var="${8:-}"
	local infrastructure_count_var="${9:-}"
	local state_file="" outcome_file="" last_fingerprint="" dispatched_at="0" cooldown="" inflight_ttl="" age_seconds="0"
	local last_attempt_count="0" next_attempt_count="1" state_repeated_same_fingerprint="$PRRTS_BOOL_FALSE"
	local last_infrastructure_failure_count="0" next_infrastructure_failure_count="0" infrastructure_failure_max=""
	local last_head_sha="" state_same_head_sha="$PRRTS_BOOL_FALSE"
	local analysis_complete="$PRRTS_BOOL_FALSE" blocked_by="" maintainer_attention="$PRRTS_BOOL_FALSE"
	local blocker_reason="" retry_stale_head_validation="$PRRTS_BOOL_FALSE" worker_contract_version=""
	local stored_contract_label="" outcome_reason="" outcome_session_count="" outcome_finished_at="0" outcome_retry_class=""
	local expected_outcome_id="" observed_outcome_id="" infrastructure_failure_cooldown=""
	local retryable_infrastructure_failure="$PRRTS_BOOL_FALSE" maintainer_gate_outcome="$PRRTS_BOOL_FALSE"
	local completed_at="0"
	state_file="$(_prrts_state_file "$repo_slug" "$pr_number")"
	outcome_file="$(_prrts_outcome_file "$repo_slug" "$pr_number")"
	cooldown="$(_prrts_normalise_int "$PR_REVIEW_THREAD_RESPONSE_COOLDOWN" "3600" "60")"
	inflight_ttl="$(_prrts_normalise_int "$PR_REVIEW_THREAD_RESPONSE_INFLIGHT_TTL" "300" "1")"
	infrastructure_failure_cooldown="$(_prrts_normalise_int "$PR_REVIEW_THREAD_RESPONSE_INFRASTRUCTURE_FAILURE_COOLDOWN" "90" "1")"
	infrastructure_failure_max="$(_prrts_normalise_int "$PR_REVIEW_THREAD_RESPONSE_INFRASTRUCTURE_FAILURE_MAX" "5" "2")"
	_prrts_read_state "$state_file" last_fingerprint dispatched_at last_attempt_count analysis_complete blocked_by maintainer_attention last_head_sha blocker_reason worker_contract_version expected_outcome_id last_infrastructure_failure_count completed_at
	_prrts_read_outcome "$outcome_file" outcome_reason outcome_session_count outcome_finished_at observed_outcome_id outcome_retry_class
	if [[ "$worker_contract_version" != "$PRRTS_WORKER_CONTRACT_VERSION" &&
		"$fingerprint" == "$last_fingerprint" &&
		"$maintainer_attention" == "$PRRTS_BOOL_TRUE" &&
		"$blocker_reason" == "same_unresolved_thread_fingerprint" &&
		(-z "$last_head_sha" || -z "$current_head_sha" || "$last_head_sha" == "$current_head_sha") ]]; then
		stored_contract_label="${worker_contract_version:-legacy}"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} retrying stale same-fingerprint escalation under worker contract ${PRRTS_WORKER_CONTRACT_VERSION} (stored=${stored_contract_label})"
		last_fingerprint=""
		dispatched_at="0"
		last_attempt_count="0"
		last_head_sha=""
		analysis_complete="$PRRTS_BOOL_FALSE"
		blocked_by=""
		maintainer_attention="$PRRTS_BOOL_FALSE"
		blocker_reason=""
		last_infrastructure_failure_count="0"
	fi
	_prrts_classify_previous_dispatch "$fingerprint" "$last_fingerprint" "$current_head_sha" "$last_head_sha" \
		"$last_attempt_count" "$expected_outcome_id" "$observed_outcome_id" "$outcome_reason" \
		"$outcome_session_count" "$outcome_finished_at" "$dispatched_at" "$now_epoch" "$outcome_retry_class" \
		"$last_infrastructure_failure_count" state_repeated_same_fingerprint state_same_head_sha next_attempt_count \
		retryable_infrastructure_failure maintainer_gate_outcome next_infrastructure_failure_count
	_prrts_set_dispatch_outputs "$attempt_var" "$next_attempt_count" "$repeated_var" "$state_repeated_same_fingerprint" \
		"$same_head_var" "$state_same_head_sha" "$infrastructure_count_var" "$next_infrastructure_failure_count"

	if _prrts_worker_active "$repo_slug" "$pr_number"; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — response worker already active"
		return "$PRRTS_RC_DISPATCH_DEFERRED"
	fi
	if [[ "$state_repeated_same_fingerprint" == "$PRRTS_BOOL_TRUE" && "$analysis_complete" == "$PRRTS_BOOL_TRUE" && "$maintainer_attention" == "$PRRTS_BOOL_TRUE" ]]; then
		if [[ "$last_attempt_count" -eq 1 ]] && _prrts_retryable_prelaunch_failure_once "$blocker_reason"; then
			retry_stale_head_validation="$PRRTS_BOOL_TRUE"
		else
			_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — analysis complete and blocked by ${blocked_by:-decision}; maintainer attention pending"
			return "$PRRTS_RC_MAINTAINER_ATTENTION"
		fi
	fi
	age_seconds=$((now_epoch - dispatched_at))
	if [[ "$maintainer_gate_outcome" == "$PRRTS_BOOL_TRUE" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — typed maintainer gate outcome=${outcome_reason} requires human action"
		return "$PRRTS_RC_MAINTAINER_ATTENTION"
	fi
	if [[ "$retryable_infrastructure_failure" == "$PRRTS_BOOL_TRUE" ]]; then
		local infrastructure_retry_status=0
		_prrts_infrastructure_retry_status "$repo_slug" "$pr_number" "$now_epoch" "$outcome_finished_at" \
			"$infrastructure_failure_cooldown" "$cooldown" "$next_infrastructure_failure_count" \
			"$infrastructure_failure_max" "$outcome_reason" || infrastructure_retry_status=$?
		if [[ "$infrastructure_retry_status" -ne 0 ]]; then
			return "$infrastructure_retry_status"
		fi
		if [[ "$next_infrastructure_failure_count" -ge "$infrastructure_failure_max" ]]; then
			next_infrastructure_failure_count=0
			[[ -n "$infrastructure_count_var" ]] && printf -v "$infrastructure_count_var" '%s' "$next_infrastructure_failure_count"
		fi
		return 0
	fi
	if [[ "$dispatched_at" -gt 0 && "$age_seconds" -lt "$inflight_ttl" ]] &&
		! _prrts_has_fresh_progress "$blocker_reason" "$analysis_complete" "$completed_at" "$dispatched_at"; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — dispatch state active ${age_seconds}s ago"
		return "$PRRTS_RC_DISPATCH_DEFERRED"
	fi
	if [[ "$state_repeated_same_fingerprint" == "$PRRTS_BOOL_TRUE" && "$state_same_head_sha" == "$PRRTS_BOOL_TRUE" && "$age_seconds" -lt "$cooldown" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — same thread fingerprint dispatched ${age_seconds}s ago"
		return "$PRRTS_RC_DISPATCH_DEFERRED"
	fi
	if [[ "$retry_stale_head_validation" == "$PRRTS_BOOL_TRUE" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} retrying stale PR head validation failure once (${blocker_reason})"
	fi
	return 0
}

_prrts_write_state() {
	local repo_slug="$1"
	local pr_number="$2"
	local fingerprint="$3"
	local thread_count="$4"
	local now_epoch="$5"
	local attempt_count="${6:-1}"
	local maintainer_attention="${7:-false}"
	local head_sha="${8:-}"
	local outcome_id="${9:-}"
	local infrastructure_failure_count="${10:-0}"
	local state_file=""
	_prrts_ensure_dirs
	[[ "$attempt_count" =~ ^[0-9]+$ ]] || attempt_count=1
	[[ "$infrastructure_failure_count" =~ ^[0-9]+$ ]] || infrastructure_failure_count=0
	state_file="$(_prrts_state_file "$repo_slug" "$pr_number")"
	{
		printf 'fingerprint=%s\n' "$fingerprint"
		printf 'dispatched_at=%s\n' "$now_epoch"
		printf 'thread_count=%s\n' "$thread_count"
		printf 'attempt_count=%s\n' "$attempt_count"
		printf 'last_head_sha=%s\n' "$head_sha"
		printf 'worker_contract_version=%s\n' "$PRRTS_WORKER_CONTRACT_VERSION"
		if [[ "$infrastructure_failure_count" -gt 0 ]]; then
			printf 'infrastructure_failure_count=%s\n' "$infrastructure_failure_count"
		fi
		if [[ -n "$outcome_id" ]]; then
			printf 'outcome_id=%s\n' "$outcome_id"
		fi
		if [[ "$maintainer_attention" == "$PRRTS_BOOL_TRUE" ]]; then
			printf 'maintainer_attention=true\n'
			printf 'attention_reason=same_unresolved_thread_fingerprint\n'
		fi
	} >"$state_file"
	return 0
}

_prrts_write_analysis_state() {
	local repo_slug="$1"
	local pr_number="$2"
	local analysis_complete="$3"
	local blocked_by="$4"
	local maintainer_attention="$5"
	local reason="$6"
	local details_file="${7:-}"
	local state_file=""
	local tmp_file=""
	local key=""
	local value=""
	local now_epoch=""
	local details=""
	local fingerprint="" dispatched_at="0" thread_count="0" attempt_count="0" last_head_sha="" worker_contract_version="" outcome_id=""
	local infrastructure_failure_count="0"
	_prrts_ensure_dirs
	state_file="$(_prrts_state_file "$repo_slug" "$pr_number")"
	if [[ -f "$state_file" ]]; then
		while IFS='=' read -r key value; do
			case "$key" in
			fingerprint) fingerprint="$value" ;;
			dispatched_at) dispatched_at="$value" ;;
			thread_count) thread_count="$value" ;;
			attempt_count) attempt_count="$value" ;;
			last_head_sha) last_head_sha="$value" ;;
			worker_contract_version) worker_contract_version="$value" ;;
			outcome_id) outcome_id="$value" ;;
			infrastructure_failure_count) infrastructure_failure_count="$value" ;;
			esac
		done <"$state_file"
	fi
	[[ "$dispatched_at" =~ ^[0-9]+$ ]] || dispatched_at=0
	[[ "$thread_count" =~ ^[0-9]+$ ]] || thread_count=0
	[[ "$attempt_count" =~ ^[0-9]+$ ]] || attempt_count=0
	[[ "$infrastructure_failure_count" =~ ^[0-9]+$ ]] || infrastructure_failure_count=0
	blocked_by="$(_prrts_normalise_blocked_by "$blocked_by")"
	reason="$(_prrts_state_value_line "$reason" 240)"
	if [[ -n "$details_file" && -f "$details_file" ]]; then
		details="$(_prrts_state_value_line "$(<"$details_file")" 700)"
	else
		details=""
	fi
	now_epoch="$(date +%s)"
	tmp_file="${state_file}.tmp.$$"
	{
		printf 'fingerprint=%s\n' "$fingerprint"
		printf 'dispatched_at=%s\n' "$dispatched_at"
		printf 'thread_count=%s\n' "$thread_count"
		printf 'attempt_count=%s\n' "$attempt_count"
		printf 'last_head_sha=%s\n' "$last_head_sha"
		if [[ -n "$worker_contract_version" ]]; then
			printf 'worker_contract_version=%s\n' "$worker_contract_version"
		fi
		if [[ "$infrastructure_failure_count" -gt 0 ]]; then
			printf 'infrastructure_failure_count=%s\n' "$infrastructure_failure_count"
		fi
		if [[ -n "$outcome_id" ]]; then
			printf 'outcome_id=%s\n' "$outcome_id"
		fi
		printf 'analysis_complete=%s\n' "$analysis_complete"
		printf 'blocked_by=%s\n' "$blocked_by"
		printf 'maintainer_attention=%s\n' "$maintainer_attention"
		printf 'attention_reason=%s\n' "$reason"
		printf 'blocker_reason=%s\n' "$reason"
		if [[ -n "$details" ]]; then
			printf 'blocker_details=%s\n' "$details"
		fi
		printf 'completed_at=%s\n' "$now_epoch"
	} >"$tmp_file"
	mv "$tmp_file" "$state_file"
	_prrts_log "state: ${repo_slug}#${pr_number} analysis_complete=${analysis_complete} blocked_by=${blocked_by} maintainer_attention=${maintainer_attention}"
	return 0
}
