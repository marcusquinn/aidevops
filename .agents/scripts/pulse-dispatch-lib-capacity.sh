#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Extracted from pulse-dispatch-lib.sh; source the orchestrator, not this file.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DISPATCH_CAPACITY_LIB_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CAPACITY_LIB_LOADED=1
_DISPATCH_UNCLASSIFIED_SIGNAL="unclassified_signal"
# GH#38048: a census handed to another runtime bundle is read only when that
# bundle writes the same candidate snapshot format.
_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA="aidevops.pulse-dispatch-candidates/v1"

_dispatch_cycle_cache_path() {
	local kind="$1"
	local suffix="${2:-}"
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local cycle_key="${_PULSE_CYCLE_ID:-pid-$$}"
	[[ "$temp_root" == /* ]] || return 1
	if [[ ! -d "$temp_root" ]]; then
		(umask 077 && mkdir -p "$temp_root") 2>/dev/null || return 1
	fi
	[[ -d "$temp_root" && ! -L "$temp_root" ]] || return 1
	cycle_key=$(printf '%s' "$cycle_key" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
	[[ -n "$cycle_key" ]] || return 1
	printf '%s/%s.%s%s\n' "$temp_root" "$kind" "$cycle_key" "$suffix"
	return 0
}

_dispatch_candidate_snapshot_path() {
	local per_repo_limit="${1:-${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}}"
	local dependency_normalization_mode="${2:-normalize}"
	local mode_suffix=""
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit=1000
	[[ "$dependency_normalization_mode" == "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP" ]] || dependency_normalization_mode="normalize"
	[[ "$dependency_normalization_mode" == "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP" ]] && mode_suffix=".skip"
	# Partial censuses survive cooperative bundle drains/cycle rollover, but
	# must never masquerade as complete product discovery in the full cache.
	if [[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 1 ]]; then
		local _PULSE_CYCLE_ID="first-wave"
		local AIDEVOPS_TEMP_DIR="${HOME}/.aidevops/cache"
		_dispatch_cycle_cache_path "pulse-dispatch-candidates" ".${per_repo_limit}${mode_suffix}.partial.json"
		return $?
	fi
	_dispatch_cycle_cache_path "pulse-dispatch-candidates" ".${per_repo_limit}${mode_suffix}.json"
	return $?
}

# A snapshot is reusable from capture for the longer of the enumeration
# estimate and the census that built it. A census read across runtime bundles
# must also carry the reader's snapshot schema (GH#38048).
# Args: $1=snapshot file $2=now epoch $3=ttl seconds $4=required schema (optional)
_dispatch_candidate_snapshot_is_fresh() {
	local snapshot_file="$1" now_epoch="$2" snapshot_ttl="$3" schema="${4:-}"
	[[ -f "$snapshot_file" && ! -L "$snapshot_file" ]] || return 1
	jq -e --argjson now "$now_epoch" --argjson ttl "$snapshot_ttl" --arg schema "$schema" \
		'type == "object" and ($schema == "" or .schema == $schema) and (.captured_at | type == "number") and .captured_at <= $now and .captured_at > ($now - ([$ttl, (.census_seconds // 0)] | max)) and (.candidates | type == "array")' \
		"$snapshot_file" >/dev/null 2>&1
	return $?
}

# GH#38048: bundle-independent slot for a full census handed across a
# cooperative drain, keyed like the cycle snapshot it carries.
_dispatch_candidate_handoff_path() {
	local per_repo_limit="${1:-${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}}"
	local dependency_normalization_mode="${2:-normalize}"
	local _PULSE_FIRST_DISPATCH_WAVE=0 _PULSE_CYCLE_ID="drain-handoff"
	local AIDEVOPS_TEMP_DIR="${HOME}/.aidevops/cache"
	_dispatch_candidate_snapshot_path "$per_repo_limit" "$dependency_normalization_mode"
	return $?
}

# GH#38048: a cooperatively drained cycle moves its full census and attempt
# ledger to the handoff slot. It launches nothing from it (GH#37907); the
# activated bundle's first wave decides whether the census is still usable.
# Args: $1=per-repo limit $2=activated bundle id
_dispatch_hand_off_candidate_snapshots() {
	local per_repo_limit="$1" bundle="$2" mode="" snapshot="" handoff=""
	local _PULSE_FIRST_DISPATCH_WAVE=0
	for mode in normalize "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP"; do
		snapshot=$(_dispatch_candidate_snapshot_path "$per_repo_limit" "$mode") || continue
		handoff=$(_dispatch_candidate_handoff_path "$per_repo_limit" "$mode") || continue
		[[ -f "$snapshot" && ! -L "$snapshot" && ! -L "${snapshot}.consumed" ]] || continue
		rm -f "$handoff" "${handoff}.consumed" 2>/dev/null || continue
		mv -f "$snapshot" "$handoff" 2>/dev/null || continue
		if [[ -f "${snapshot}.consumed" ]] && ! mv -f "${snapshot}.consumed" "${handoff}.consumed" 2>/dev/null; then
			rm -f "$handoff" 2>/dev/null || true
			continue
		fi
		echo "[pulse-wrapper] Dispatch candidate census handed to activated bundle ${bundle}: mode=${mode} (GH#38048)" >>"$LOGFILE"
	done
	return 0
}

# GH#38048: installs a handoff census and its attempt ledger as the durable
# snapshot. Attempt keys of a still-fresh destination snapshot are kept and an
# expired one's are dropped, as for an expired partial in
# _dispatch_ranked_candidates_json. The ledger is installed before the census,
# so a failed transfer never leaves an adopted census without attempt history.
# Args: $1=handoff $2=target snapshot $3=now epoch $4=ttl seconds
# Returns: 0 installed, 1 handoff not usable, 2 transfer failed
_dispatch_install_candidate_handoff() {
	local handoff="$1" snapshot_file="$2" now_epoch="$3" snapshot_ttl="$4"
	local ledger="" target_ledger="${snapshot_file}.consumed" transfer_rc=0
	[[ ! -L "${handoff}.consumed" && ! -L "$snapshot_file" && ! -d "$snapshot_file" ]] || return 1
	_dispatch_candidate_snapshot_is_fresh "$handoff" "$now_epoch" "$snapshot_ttl" "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" || return 1
	ledger=$(mktemp "${target_ledger}.tmp.XXXXXX" 2>/dev/null) || return 2
	if [[ -f "${handoff}.consumed" ]]; then
		cat "${handoff}.consumed" >>"$ledger" 2>/dev/null || transfer_rc=2
	fi
	if [[ "$transfer_rc" -eq 0 && -f "$target_ledger" && ! -L "$target_ledger" ]] &&
		_dispatch_candidate_snapshot_is_fresh "$snapshot_file" "$now_epoch" "$snapshot_ttl"; then
		cat "$target_ledger" >>"$ledger" 2>/dev/null || transfer_rc=2
	fi
	if [[ "$transfer_rc" -eq 0 ]] && mv -f "$ledger" "$target_ledger" 2>/dev/null &&
		mv -f "$handoff" "$snapshot_file" 2>/dev/null; then
		rm -f "${handoff}.consumed" 2>/dev/null || true
		return 0
	fi
	rm -f "$ledger" 2>/dev/null || true
	return 2
}

# GH#38048: a first wave or bounded census adopts a drained cycle's full
# census as its durable snapshot, so the activated bundle starts from known
# work without a new scan. A skip round may take a normalized census, never
# the reverse. A handoff past its reuse window, with another schema, on an
# unsafe path or whose ledger cannot be transferred is removed unserved.
# Adopted candidates still pass the registry/schedule recheck and every live
# dispatch gate.
# Args: $1=target snapshot $2=per-repo limit $3=mode $4=now epoch $5=ttl seconds
_dispatch_adopt_candidate_handoff() {
	local snapshot_file="$1" per_repo_limit="$2" mode="$3" now_epoch="$4" snapshot_ttl="$5"
	local source_mode="" handoff="" adopted=0 outcome="" install_rc=0
	for source_mode in normalize "$mode"; do
		handoff=$(_dispatch_candidate_handoff_path "$per_repo_limit" "$source_mode") || continue
		[[ -e "$handoff" || -L "$handoff" ]] || continue
		outcome="superseded"
		if [[ "$adopted" -eq 0 ]]; then
			install_rc=0
			_dispatch_install_candidate_handoff "$handoff" "$snapshot_file" "$now_epoch" "$snapshot_ttl" || install_rc=$?
			if [[ "$install_rc" -eq 0 ]]; then
				adopted=1
				_dispatch_stats_increment "dispatch_candidate_handoff_adopted"
				echo "[pulse-wrapper] Dispatch candidate census handoff adopted: source_mode=${source_mode} mode=${mode} (GH#38048)" >>"$LOGFILE"
				continue
			fi
			outcome="stale_or_invalid"
			[[ "$install_rc" -eq 1 ]] || outcome="transfer_failed"
		fi
		rm -f "$handoff" "${handoff}.consumed" 2>/dev/null || true
		_dispatch_stats_increment "dispatch_candidate_handoff_discarded"
		echo "[pulse-wrapper] Dispatch candidate census handoff discarded: reason=${outcome} source_mode=${source_mode} (GH#38048)" >>"$LOGFILE"
	done
	[[ "$adopted" -eq 1 ]]
	return $?
}

# The census is written under PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT, so cleanup
# and invalidation default to that key, not to the runnable-count sample size.
_dispatch_cleanup_cycle_cache() {
	local per_repo_limit="${1:-${PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT:-1000}}"
	local _PULSE_FIRST_DISPATCH_WAVE=0
	local candidate_file="" skip_candidate_file="" triage_file="" cache_file="" drain_bundle=""
	# GH#38048: under a cooperative drain the full census outlives its cycle.
	# The marker exists only while this process owns the instance lock.
	if declare -F _pulse_drain_requested_bundle >/dev/null 2>&1 && drain_bundle=$(_pulse_drain_requested_bundle); then
		_dispatch_hand_off_candidate_snapshots "$per_repo_limit" "$drain_bundle"
	fi
	candidate_file=$(_dispatch_candidate_snapshot_path "$per_repo_limit" 2>/dev/null || true)
	skip_candidate_file=$(_dispatch_candidate_snapshot_path "$per_repo_limit" "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP" 2>/dev/null || true)
	triage_file=$(_dispatch_cycle_cache_path "pulse-triage-prepass" ".done" 2>/dev/null || true)
	for cache_file in "$candidate_file" "$skip_candidate_file" "$triage_file"; do
		[[ -n "$cache_file" && ( -f "$cache_file" || -L "$cache_file" ) ]] || continue
		rm -f "$cache_file" "${cache_file}.consumed" 2>/dev/null || true
	done
	return 0
}

_dispatch_invalidate_candidate_snapshot() {
	local reason="${1:-state_mutation}"
	local per_repo_limit="${2:-${PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT:-1000}}"
	local snapshot_file="" dependency_normalization_mode="" removed_snapshot=0
	local _PULSE_FIRST_DISPATCH_WAVE=0 wave=""
	for wave in 0 1 handoff; do
		# A worker exit frees capacity, not candidate eligibility. Preserve the
		# durable remainder even if the refill's later dispatch gates block it;
		# eligibility mutations still invalidate both waves below, and an
		# unadopted drain handoff with them (GH#38048).
		[[ "$reason" == "event_refill" && "$wave" != 0 ]] && continue
		[[ "$wave" == handoff ]] || _PULSE_FIRST_DISPATCH_WAVE="$wave"
		for dependency_normalization_mode in normalize "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP"; do
			if [[ "$wave" == handoff ]]; then
				snapshot_file=$(_dispatch_candidate_handoff_path "$per_repo_limit" "$dependency_normalization_mode") || continue
			else
				snapshot_file=$(_dispatch_candidate_snapshot_path "$per_repo_limit" "$dependency_normalization_mode") || continue
			fi
			if [[ -f "$snapshot_file" && ! -L "$snapshot_file" ]]; then
				rm -f "$snapshot_file" "${snapshot_file}.consumed" 2>/dev/null || return 1
				removed_snapshot=1
			fi
		done
	done
	if [[ "$removed_snapshot" -eq 1 ]]; then
		echo "[pulse-wrapper] Dispatch candidate snapshot invalidated: reason=${reason}" >>"$LOGFILE"
	fi
	return 0
}

# Append-only consumption survives dispatch command substitutions and floor
# refills. Each candidate still passes the authoritative live ceremony gate.
_dispatch_ranked_candidate_consumed() {
	local candidate_json="$1" snapshot="" key=""
	local _PULSE_FIRST_DISPATCH_WAVE=0 wave="" mode=""
	key=$(jq -cr '[.repo_slug,.number]' <<<"$candidate_json") || return 0
	# Bounded enumeration runs in a command substitution: its dynamic wave
	# flag is gone by the time the serial/parallel loop records an attempt.
	for wave in 0 1; do
		_PULSE_FIRST_DISPATCH_WAVE="$wave"
		for mode in normalize "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP"; do
			snapshot=$(_dispatch_candidate_snapshot_path "${PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT:-1000}" "$mode") || continue
			[[ -f "$snapshot" && ! -L "$snapshot" && ! -L "${snapshot}.consumed" ]] || continue
			printf '%s\n' "$key" >>"${snapshot}.consumed"
		done
	done
	return 0
}

# Ordering hint only: expired remainder still identifies repositories worth
# rechecking first. Live ceremony, schedules and interval gates remain binding.
_dispatch_first_wave_backlog_repos() {
	local _PULSE_FIRST_DISPATCH_WAVE=1 mode="" snapshot="" candidates="[]"
	for mode in normalize "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP"; do
		snapshot=$(_dispatch_candidate_snapshot_path "${PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT:-1000}" "$mode") || continue
		[[ -f "$snapshot" && ! -L "$snapshot" ]] || continue
		candidates=$(jq -ce '.candidates | arrays' "$snapshot" 2>/dev/null) || continue
		_dispatch_filter_consumed_ranked_candidates "$snapshot" "$candidates" | jq -r '.[].repo_slug // empty'
	done
	return 0
}

_dispatch_filter_consumed_ranked_candidates() {
	local snapshot="$1" candidates="$2" consumed="[]"
	if [[ -f "${snapshot}.consumed" && ! -L "${snapshot}.consumed" ]]; then
		consumed=$(jq -sc '.' "${snapshot}.consumed") || consumed="[]"
	fi
	jq -c --argjson consumed "$consumed" 'map(select([.repo_slug,.number] as $key | $consumed | any(. == $key) | not))' <<<"$candidates"
	return $?
}

# A durable remainder crosses cycle boundaries: recheck current registry paths
# and schedules before reuse. Interval throttling applies to API polling, not
# to attempting already-enumerated work. No network census is needed here.
_dispatch_filter_partial_snapshot_candidates() {
	local candidates="$1" allowed="" slug="" path="" priority="" start="" end="" expires="" interval=""
	local _PULSE_FIRST_DISPATCH_WAVE=0
	[[ -f "${REPOS_JSON:-}" ]] || { printf '[]\n'; return 0; }
	allowed=$(
		while IFS='|' read -r slug path priority start end expires interval; do
			check_repo_pulse_schedule "$slug" "$start" "$end" "$expires" "$REPOS_JSON" || continue
			jq -nc --arg slug "$slug" --arg path "$path" '{repo_slug:$slug,repo_path:$path}'
		done < <(_dispatch_repository_rows "")
	) || return 1
	jq -cs --argjson candidates "$candidates" '. as $allowed |
		$candidates | map(select({repo_slug,repo_path} as $repo | $allowed | index($repo)))' <<<"$allowed"
	return $?
}

_dispatch_ranked_candidates_json() {
	local per_repo_limit="${1:-${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}}"
	local dependency_normalization_mode="${2:-normalize}"
	local snapshot_file="" snapshot_tmp="" candidates_json="[]"
	local now_epoch="" snapshot_ttl=300 started_epoch=0 snapshot_fresh=0
	now_epoch=$(date +%s) || return 1
	started_epoch="$now_epoch"
	if declare -F _dispatch_enumeration_expected_seconds >/dev/null 2>&1; then
		snapshot_ttl=$(_dispatch_enumeration_expected_seconds)
	fi
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit=1000
	[[ "$dependency_normalization_mode" == "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP" ]] || dependency_normalization_mode="normalize"
	if [[ "${PULSE_DISPATCH_CANDIDATE_SNAPSHOT_ENABLED:-1}" == "0" ]]; then
		build_ranked_dispatch_candidates_json "$per_repo_limit" "$dependency_normalization_mode"
		return $?
	fi
	snapshot_file=$(_dispatch_candidate_snapshot_path "$per_repo_limit" "$dependency_normalization_mode") || {
		build_ranked_dispatch_candidates_json "$per_repo_limit" "$dependency_normalization_mode"
		return $?
	}
	# GH#38048: the activated bundle's first wave starts from a drained
	# cycle's full census when one was handed over.
	if [[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 1 ]]; then
		_dispatch_adopt_candidate_handoff "$snapshot_file" "$per_repo_limit" "$dependency_normalization_mode" "$now_epoch" "$snapshot_ttl" || true
	fi
	if _dispatch_candidate_snapshot_is_fresh "$snapshot_file" "$now_epoch" "$snapshot_ttl"; then
		snapshot_fresh=1
		candidates_json=$(jq -c '.candidates' "$snapshot_file") || return 1
		candidates_json=$(_dispatch_filter_consumed_ranked_candidates "$snapshot_file" "$candidates_json") || return 1
		if [[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 1 ]]; then
			candidates_json=$(_dispatch_filter_partial_snapshot_candidates "$candidates_json") || return 1
		fi
		if [[ "$candidates_json" != '[]' ]]; then
			printf '%s\n' "$candidates_json"
			_dispatch_stats_increment "dispatch_candidate_snapshot_hit"
			return 0
		fi
	fi
	if [[ -L "$snapshot_file" ]]; then
		rm -f "$snapshot_file" 2>/dev/null || {
			build_ranked_dispatch_candidates_json "$per_repo_limit" "$dependency_normalization_mode"
			return $?
		}
	fi
	candidates_json=$(build_ranked_dispatch_candidates_json "$per_repo_limit" "$dependency_normalization_mode") || return 1
	if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$candidates_json"; then
		return 1
	fi
	# TTL starts at completion, not at the beginning of an expensive census.
	# Keep same-census attempts across exhaustion/refills, but let expired
	# durable first waves retry candidates after their normal live cooldown.
	if [[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 1 && "$snapshot_fresh" == 0 ]]; then
		rm -f "${snapshot_file}.consumed" 2>/dev/null || return 1
	fi
	now_epoch=$(date +%s) || return 1
	((now_epoch - started_epoch <= snapshot_ttl)) || snapshot_ttl=$((now_epoch - started_epoch))
	# Exhaustion must not perpetually renew the durable attempt ledger's TTL.
	if [[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 1 && "$snapshot_fresh" == 1 ]]; then
		now_epoch=$(jq -r '.captured_at' "$snapshot_file") || return 1
	fi
	snapshot_tmp=$(mktemp "${snapshot_file}.tmp.XXXXXX" 2>/dev/null || true)
	if [[ -n "$snapshot_tmp" ]] && (umask 077 && jq -nc --arg schema "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" --argjson captured_at "$now_epoch" \
		--argjson census_seconds "$snapshot_ttl" --argjson candidates "$candidates_json" '{schema:$schema,captured_at:$captured_at,census_seconds:$census_seconds,candidates:$candidates}' >"$snapshot_tmp") 2>/dev/null; then
		mv "$snapshot_tmp" "$snapshot_file" 2>/dev/null || rm -f "$snapshot_tmp" 2>/dev/null || true
	elif [[ -n "$snapshot_tmp" ]]; then
		rm -f "$snapshot_tmp" 2>/dev/null || true
	fi
	_dispatch_stats_increment "dispatch_candidate_snapshot_miss"
	_dispatch_filter_consumed_ranked_candidates "$snapshot_file" "$candidates_json"
	return 0
}

# Cache only claims with explicit TTL evidence. The newest trusted comment must
# still be that exact, unedited dispatch claim. A release, new claim, edit,
# deleted comment or failed lookup immediately falls through to live ceremony.
_dispatch_claim_cache_evidence() {
	local issue="$1" repo="$2" comments=""
	comments=$(gh api --paginate "repos/${repo}/issues/${issue}/comments?per_page=100" \
		--jq '[.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")]' 2>/dev/null) || return 1
	jq -cse 'add | sort_by(.created_at,.id) | last // empty | select((.body // "") | test("(^|\n)Dispatching worker")) | {id,created_at,updated_at}' <<<"$comments"
	return $?
}

_dispatch_claim_cache_record() {
	local issue="$1" repo="$2" lines="$3" path="" evidence="" temporary="" now=0 ttl=0
	local ttl_pattern='(TTL:|window:) ([0-9]+)s remaining'
	[[ "$lines" =~ $ttl_pattern ]] || return 0
	ttl="${BASH_REMATCH[2]}"
	[[ "$ttl" =~ ^[1-9][0-9]{0,4}$ ]] && ((ttl <= 7200)) || return 0
	now=$(date +%s) || return 0
	path=$(_dispatch_negative_cache_path "$issue" "$repo") || return 0
	evidence=$(_dispatch_claim_cache_evidence "$issue" "$repo") || return 0
	mkdir -p "${path%/*}" || return 0
	temporary=$(mktemp "${path}.claim.XXXXXX") || return 0
	if (umask 077 && jq -nc --argjson evidence "$evidence" --argjson expires "$((now + ttl))" \
		'{evidence:$evidence,expires:$expires}' >"$temporary"); then
		mv -f "$temporary" "${path}.claim" || rm -f "$temporary"
	else
		rm -f "$temporary"
	fi
	return 0
}

_dispatch_claim_cache_hit() {
	local issue="$1" repo="$2" path="" now=0 evidence=""
	path=$(_dispatch_negative_cache_path "$issue" "$repo") || return 1
	path="${path}.claim"
	[[ -f "$path" && ! -L "$path" ]] || return 1
	now=$(date +%s) || return 1
	jq -e --argjson now "$now" '.expires > $now and .expires <= ($now + 7200)' "$path" >/dev/null 2>&1 || return 1
	evidence=$(_dispatch_claim_cache_evidence "$issue" "$repo") || return 1
	jq -e --argjson evidence "$evidence" '.evidence == $evidence' "$path" >/dev/null 2>&1 || return 1
	return 0
}

_dispatch_triage_outcome_is_valid() {
	local outcome_json="$1"
	jq -e --arg schema "$_DISPATCH_TRIAGE_OUTCOME_SCHEMA" '
		type == "object"
		and .schema == $schema
		and ([.attempted, .posted, .review_failed, .infrastructure_failed, .preparation_failed]
			| all(type == "number" and floor == . and . >= 0))
		and .attempted == (.posted + .review_failed + .infrastructure_failed)
	' >/dev/null 2>&1 <<<"$outcome_json"
	return $?
}

_dispatch_triage_fallback_outcome() {
	local infrastructure_failed="$1"
	jq -cn \
		--arg schema "$_DISPATCH_TRIAGE_OUTCOME_SCHEMA" \
		--argjson infrastructure_failed "$infrastructure_failed" \
		'{schema:$schema, attempted:$infrastructure_failed, posted:0, review_failed:0, infrastructure_failed:$infrastructure_failed, preparation_failed:0}'
	return $?
}

_dispatch_triage_outcomes_sum() {
	local prior_outcome="$1"
	local current_outcome="$2"
	jq -cn \
		--arg schema "$_DISPATCH_TRIAGE_OUTCOME_SCHEMA" \
		--argjson prior "$prior_outcome" \
		--argjson current "$current_outcome" \
		'{schema:$schema,
		attempted:($prior.attempted + $current.attempted),
		posted:($prior.posted + $current.posted),
		review_failed:($prior.review_failed + $current.review_failed),
		infrastructure_failed:($prior.infrastructure_failed + $current.infrastructure_failed),
		preparation_failed:($prior.preparation_failed + $current.preparation_failed)}'
	return $?
}

_dispatch_triage_marker_refresh_is_due() {
	local triage_marker="$1"
	local refresh_interval="${PULSE_TRIAGE_REFRESH_INTERVAL_SECONDS:-300}"
	local marker_mtime=0 now_epoch=0 marker_age=0
	[[ "$refresh_interval" =~ ^[0-9]+$ ]] || refresh_interval=300
	[[ -f "$triage_marker" && ! -L "$triage_marker" ]] || return 0
	marker_mtime=$(_file_mtime_epoch "$triage_marker" 2>/dev/null) || return 0
	now_epoch=$(date +%s 2>/dev/null) || return 1
	[[ "$marker_mtime" =~ ^[0-9]+$ ]] || return 0
	marker_age=$((now_epoch - marker_mtime))
	[[ "$marker_age" -ge "$refresh_interval" ]]
	return $?
}

_dispatch_write_triage_marker() {
	local triage_marker="$1"
	local triage_outcome="$2"
	local triage_marker_tmp=""
	[[ -n "$triage_marker" && ! -L "$triage_marker" ]] || return 1
	triage_marker_tmp=$(mktemp "${triage_marker}.tmp.XXXXXX" 2>/dev/null) || return 1
	if (umask 077 && printf '%s\n' "$triage_outcome" >"$triage_marker_tmp") 2>/dev/null && \
		mv "$triage_marker_tmp" "$triage_marker" 2>/dev/null; then
		return 0
	fi
	rm -f "$triage_marker_tmp" 2>/dev/null || true
	return 1
}

#######################################
# Emit per-candidate debug output for the dispatch_max (GH#18804).
#
# Always writes to LOGFILE (so the operator sees it in pulse.log). When
# PULSE_DEBUG is set to a truthy value, the message is prefixed with DEBUG:
# and emitted unconditionally — useful for one-off operator runs that need
# verbose per-candidate visibility into label state, dedup probes, and skip
# decisions.
#
# Arguments:
#   $1 - message body (plain text, no leading prefix)
# Returns: 0 always
#######################################
pulse_dispatch_debug_log() {
	local message="$1"
	case "${PULSE_DEBUG:-}" in
	1 | true | TRUE | yes | YES | on | ON)
		echo "[pulse-wrapper] DFF DEBUG: ${message}" >>"$LOGFILE"
		;;
	esac
	return 0
}

#######################################
# Increment a pulse-stats counter when the stats helper is loaded.
#
# Arguments:
#   $1 - counter name
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_increment() {
	local counter_name="$1"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "$counter_name" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Increment the aggregate dispatch-candidate failure counter plus a stable
# reason-coded counter.
#
# Arguments:
#   $1 - low-cardinality reason token
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_increment_candidate_failed() {
	local reason="$1"
	case "$reason" in
		stale_draft_checkpoint | worker_draft_checkpoint_blocked)
			;;
		blocked_by_native_lookup_unavailable | blocked_by_unresolved | brief_scope_hold | canary_failed | consolidated | cooldown_no_worker_process | cost_budget_exceeded | dedup_active_claim | dedup_active_claim_live_owner | dedup_active_claim_stale_owner | dedup_active_claim_zero_attempt | dedup_active_claim_current_cycle | dedup_active_claim_durable_launch | dedup_active_claim_unverified | dependabot_target_owned | dependabot_target_unverified | dirty_worktree_recovery | dirty_worktree_evidence_unavailable | ever_nmr_without_approval | footprint_overlap | graphql_circuit_breaker | healthy_pr_backlog | interactive_review_hold | issue_closed | issue_metadata_unavailable | launch_error | local_capacity_gate | missing_worker_context | needs_maintainer_permissions | no_auto_dispatch | no_dispatchable_evidence | no_recent_log_evidence | parent_task | permission_grant_unverified | policy_gate | pr_lookup_uncertain | pr_target_not_dispatchable | provider_rate_limit_pressure | publication_pending | renovate_dependency_dashboard | repeated_failure_pressure | rest_core_circuit_breaker | runner_capability_unmet | runner_health_circuit_breaker | terminal_blocker_circuit | terminal_blocker_fleet_hold | unclassified_signal)
			;;
		*)
			reason="$_DISPATCH_UNCLASSIFIED_SIGNAL"
			;;
	esac
	_dispatch_stats_increment "dispatch_candidate_failed"
	_dispatch_stats_increment "dispatch_candidate_failed_reason_${reason}"
	return 0
}

#######################################
# Read only this candidate's bounded log evidence since its latest attempt.
# Other candidates can run concurrently; old reasons for the same issue must
# never be attributed to a new attempt that failed before emitting a blocker.
#######################################
_dispatch_candidate_recent_lines() {
	local issue_number="$1" repo_slug="$2"
	[[ -n "${LOGFILE:-}" && -f "$LOGFILE" ]] || return 0
	awk -v issue="#${issue_number}" -v repo="$repo_slug" '
		function exact_token(line, token, kind, offset, pos, previous, following) {
			offset = 1
			while ((pos = index(substr(line, offset), token)) > 0) {
				pos += offset - 1
				previous = pos == 1 ? "" : substr(line, pos - 1, 1)
				following = substr(line, pos + length(token), 1)
				if (kind == "issue" && following !~ /[0-9]/) return 1
				if (kind == "repo" && previous !~ /[[:alnum:]_.\/-]/ && following !~ /[[:alnum:]_.\/-]/) return 1
				offset = pos + length(token)
			}
			return 0
		}
		exact_token($0, issue, "issue") && exact_token($0, repo, "repo") {
			if (index($0, "DISPATCH_CANDIDATE_ATTEMPT ")) { n = 0; next }
			lines[++n] = $0
		}
		END {
			start = n - 20
			if (start < 1) { start = 1 }
			for (i = start; i <= n; i++) { print lines[i] }
		}
	' "$LOGFILE" 2>/dev/null
	return $?
}

#######################################
# Classify a failed dispatch_with_dedup return using recent candidate log lines.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - dispatch rc
#   $4 - optional pre-accounting log snapshot (may be empty)
# Stdout: low-cardinality reason token
#######################################
_dispatch_candidate_failure_reason() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_rc="$3"
	local recent_lines=""
	local reason="no_recent_log_evidence"

	if [[ "$dispatch_rc" -eq 124 ]]; then
		printf 'launch_error\n'
		return 0
	fi
	if [[ "$dispatch_rc" -eq 2 ]]; then
		printf 'canary_failed\n'
		return 0
	fi

	if [[ "${4+x}" == x ]]; then
		recent_lines="$4"
	else
		recent_lines=$(_dispatch_candidate_recent_lines "$issue_number" "$repo_slug") || recent_lines=""
	fi

	# Structured candidate-local evidence is authoritative. Generic claim prose
	# can accompany unverified ownership or an unrelated final gate; treating it
	# as a benign active claim hides the actionable prerequisite (GH#33623).
	if [[ "$recent_lines" == *"DISPATCH_BLOCK_REASON reason="* ]]; then
		reason=$(printf '%s\n' "$recent_lines" | awk '
			match($0, /DISPATCH_BLOCK_REASON reason=[a-z_]+/) {
				reason = substr($0, RSTART, RLENGTH)
				sub(/^DISPATCH_BLOCK_REASON reason=/, "", reason)
			}
			END { if (reason != "") { print reason } }
		') || reason="$_DISPATCH_UNCLASSIFIED_SIGNAL"
		[[ -n "$reason" ]] || reason="$_DISPATCH_UNCLASSIFIED_SIGNAL"
		printf '%s\n' "$reason"
		return 0
	fi

	if [[ "$recent_lines" == *"has active dispatch comment"* || "$recent_lines" == *"active claim"* ]]; then
		printf 'dedup_active_claim\n'
		return 0
	fi

	if [[ -x "${SCRIPT_DIR:-}/dispatch-dedup-helper.sh" && -n "$recent_lines" ]]; then
		reason=$("${SCRIPT_DIR}/dispatch-dedup-helper.sh" classify-blocker "$recent_lines" 2>/dev/null) || reason="$_DISPATCH_UNCLASSIFIED_SIGNAL"
		[[ -n "$reason" ]] || reason="$_DISPATCH_UNCLASSIFIED_SIGNAL"
	fi

	printf '%s\n' "$reason"
	return 0
}

#######################################
# Return success when a dispatch candidate reason is an expected benign block.
#
# Arguments:
#   $1 - low-cardinality reason token
# Returns:
#   0 - benign block reason
#   1 - not a benign block reason
#######################################
_dispatch_candidate_benign_block_reason() {
	local reason="$1"
	case "$reason" in
		stale_draft_checkpoint | worker_draft_checkpoint_blocked)
			return 0
			;;
		blocked_by_unresolved | brief_scope_hold | consolidated | dedup_active_claim | dedup_active_claim_live_owner | dedup_active_claim_durable_launch | dependabot_target_owned | dirty_worktree_recovery | footprint_overlap | interactive_review_hold | issue_closed | needs_maintainer_permissions | no_auto_dispatch | parent_task | permission_grant_unverified | policy_gate | pr_target_not_dispatchable | publication_pending | renovate_dependency_dashboard | terminal_blocker_backoff | terminal_blocker_circuit | terminal_blocker_fleet_hold | zero_attempt_backoff)
			return 0
			;;
	esac
	return 1
}

#######################################
# Detect unresolved recent worker-dirty-worktree recovery markers on an issue.
#
# A dirty marker means a worker edited local files but crashed before it could
# commit or open a PR. Redispatching another worker before recovery duplicates
# effort and can overwrite the only useful evidence. Hold briefly unless a later
# maintainer/worker comment explicitly marks recovery as resolved.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - recent unresolved marker, or evidence unavailable (conservative hold)
#   1 - verified no active marker, expired marker, or disabled
#######################################
_dispatch_recent_dirty_worktree_marker_active() {
	local issue_number="$1"
	local repo_slug="$2"
	local hold_seconds="${DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS:-900}"
	_DISPATCH_DIRTY_MARKER_STATE="$_DISPATCH_VALUE_UNKNOWN"
	_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="local_state_failed"
	_DISPATCH_DIRTY_MARKER_REQUEST_ATTEMPTED="$_DISPATCH_VALUE_UNKNOWN"
	_DISPATCH_DIRTY_MARKER_DEFERRED_BY="none"
	_DISPATCH_DIRTY_MARKER_RETRY_AT="$_DISPATCH_VALUE_UNKNOWN"
	_DISPATCH_DIRTY_MARKER_EXIT_CODE="0"

	[[ "$hold_seconds" =~ ^[0-9]+$ ]] || hold_seconds="900"
	if [[ "$hold_seconds" -eq 0 ]]; then
		_DISPATCH_DIRTY_MARKER_STATE="clear"
		_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="verified_clear"
		return 1
	fi

	local comments_json="" since_iso="" now_epoch="${AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH:-}"
	local transport_error="" transport_error_template="" transport_diagnostic="" diagnostic_line="" gh_rc=0
	[[ -n "$now_epoch" ]] || now_epoch=$(date +%s) || return 0
	since_iso=$(python3 "${_PULSE_DISPATCH_LIB_DIR}/pulse-dirty-worktree-marker.py" \
		--since "$hold_seconds" "$now_epoch") || return 0
	# Only comments updated within the hold window can contain an active marker
	# or a later resolution. Still paginate: a busy thread can exceed one page.
	transport_error_template=$(_dispatch_cycle_cache_path "pulse-dirty-marker-transport" ".XXXXXX") || return 0
	transport_error=$(mktemp "$transport_error_template" 2>/dev/null) || return 0
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100&since=${since_iso}" \
		--paginate --slurp 2>"$transport_error") || gh_rc=$?
	if [[ "$gh_rc" -ne 0 ]]; then
		_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="transport_failed"
		_DISPATCH_DIRTY_MARKER_EXIT_CODE="$gh_rc"
		while IFS= read -r diagnostic_line; do
			case "$diagnostic_line" in
			*"[gh-transport] error_kind=github-api-read-deferred "*) transport_diagnostic="$diagnostic_line" ;;
			esac
		done <"$transport_error"
		if [[ -n "$transport_diagnostic" ]]; then
			_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="transport_deferred"
			if [[ "$transport_diagnostic" =~ attempted=(true|false) ]]; then
				_DISPATCH_DIRTY_MARKER_REQUEST_ATTEMPTED="${BASH_REMATCH[1]}"
			fi
			if [[ "$transport_diagnostic" =~ deferred_by=([A-Za-z0-9_.:-]+) ]]; then
				_DISPATCH_DIRTY_MARKER_DEFERRED_BY="${BASH_REMATCH[1]}"
			fi
			if [[ "$transport_diagnostic" =~ retry_at=([A-Za-z0-9_.:-]+) ]]; then
				_DISPATCH_DIRTY_MARKER_RETRY_AT="${BASH_REMATCH[1]}"
			fi
		fi
		rm -f "$transport_error" 2>/dev/null || true
		return 0
	fi
	rm -f "$transport_error" 2>/dev/null || true
	_DISPATCH_DIRTY_MARKER_REQUEST_ATTEMPTED="true"

	local marker_state=""
	marker_state=$(printf '%s' "$comments_json" | \
		python3 "${_PULSE_DISPATCH_LIB_DIR}/pulse-dirty-worktree-marker.py" \
			"$hold_seconds" "$now_epoch") || {
		_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="unparsable"
		return 0
	}
	_DISPATCH_DIRTY_MARKER_STATE="$marker_state"

	case "$marker_state" in
	clear)
		_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="verified_clear"
		return 1
		;;
	expired:*)
		_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="verified_expired"
		return 1
		;;
	*) _DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="confirmed_marker" ;;
	esac
	return 0
}

#######################################
# Parse the creator PID from an exact framework-managed benign-ledger name.
#
# Arguments:
#   $1 - file basename
# Stdout: creator PID
# Returns: 0 for an exact managed name, 1 otherwise
#######################################
_dispatch_benign_blocks_owner_pid() {
	local basename="$1"
	if [[ "$basename" =~ ^benign-blocks\.([1-9][0-9]*)\.([[:alnum:]]{6}|[0-9]{1,5})$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

#######################################
# Remove exact framework-managed ledgers whose creator PID is no longer alive.
# Live-owner files, symlinks, foreign-owned files, and near-matches survive.
#
# Arguments:
#   $1 - private managed scratch directory
# Returns: 0 on a safe scan, 1 when the directory boundary is unsafe
#######################################
_dispatch_cleanup_managed_benign_blocks() {
	local scratch_dir="$1"
	local candidate=""
	local basename=""
	local owner_pid=""
	[[ -d "$scratch_dir" && ! -L "$scratch_dir" && -O "$scratch_dir" ]] || return 1
	for candidate in "$scratch_dir"/benign-blocks.*.*; do
		[[ -f "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || continue
		basename="${candidate##*/}"
		owner_pid=$(_dispatch_benign_blocks_owner_pid "$basename") || continue
		if ! kill -0 "$owner_pid" 2>/dev/null; then
			rm -f "$candidate" 2>/dev/null || true
		fi
	done
	return 0
}

#######################################
# Remove age-qualified legacy ledgers whose old names carry no reliable owner.
# The exact historical mktemp and numeric-fallback grammars are the only files
# eligible for migration cleanup.
#
# Returns: 0 always; migration cleanup must never block pulse startup
#######################################
_dispatch_cleanup_legacy_benign_blocks() {
	local logs_dir="${HOME}/.aidevops/logs"
	local candidate=""
	local basename=""
	local modified=""
	local now=""
	local age=0
	[[ -d "$logs_dir" ]] || return 0
	command -v _file_mtime_epoch >/dev/null 2>&1 || return 0
	now=$(date +%s 2>/dev/null) || return 0
	[[ "$now" =~ ^[0-9]+$ ]] || return 0
	for candidate in "$logs_dir"/pulse-dispatch-benign-blocks.*; do
		[[ -f "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || continue
		basename="${candidate##*/}"
		if [[ "$basename" =~ ^pulse-dispatch-benign-blocks\.[[:alnum:]]{6}$ ]]; then
			:
		elif [[ "$basename" =~ ^pulse-dispatch-benign-blocks\.[1-9][0-9]*\.[0-9]{1,5}$ ]]; then
			:
		else
			continue
		fi
		modified=$(_file_mtime_epoch "$candidate") || continue
		[[ "$modified" =~ ^[0-9]+$ && "$now" -ge "$modified" ]] || continue
		age=$((now - modified))
		[[ "$age" -ge "$_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS" ]] || continue
		rm -f "$candidate" 2>/dev/null || true
	done
	return 0
}

#######################################
# Reap stale managed and legacy benign ledgers at the exclusive startup gate.
#
# Returns: 0 always; stale-file cleanup is best effort
#######################################
_dispatch_cleanup_stale_benign_blocks() {
	local scratch_dir="${HOME}/.aidevops/logs/.pulse-dispatch-benign-blocks"
	if [[ -d "$scratch_dir" && ! -L "$scratch_dir" && -O "$scratch_dir" ]]; then
		_dispatch_cleanup_managed_benign_blocks "$scratch_dir" || true
	fi
	_dispatch_cleanup_legacy_benign_blocks || true
	return 0
}

#######################################
# Prepare the private scratch boundary used by framework-managed ledgers.
#
# Returns: 0 when the directory is safe, 1 otherwise
#######################################
_dispatch_prepare_benign_blocks_scratch_dir() {
	local logs_dir="${HOME}/.aidevops/logs"
	local scratch_dir="${logs_dir}/.pulse-dispatch-benign-blocks"
	if ! mkdir -p "$logs_dir"; then
		return 1
	fi
	if [[ ! -e "$scratch_dir" && ! -L "$scratch_dir" ]]; then
		if ! (umask 077 && mkdir "$scratch_dir" 2>/dev/null); then
			[[ -d "$scratch_dir" && ! -L "$scratch_dir" ]] || return 1
		fi
	fi
	[[ -d "$scratch_dir" && ! -L "$scratch_dir" && -O "$scratch_dir" ]] || return 1
	chmod 0700 "$scratch_dir" 2>/dev/null || return 1
	_DISPATCH_BENIGN_BLOCKS_SCRATCH_DIR="$scratch_dir"
	_dispatch_cleanup_managed_benign_blocks "$scratch_dir" || return 1
	return 0
}

#######################################
# Start a cycle-local benign block ledger. Reinitializing the ledger for every
# dispatch_max cycle prevents stale active-claim blocks from a long-running
# pulse-wrapper process from suppressing later cycles after the claim clears.
#
# Stdout: file path
# Returns: 0 always
#######################################
_dispatch_begin_benign_blocks_cycle() {
	local ledger_file=""
	local ledger_managed_by_dispatch="0"
	local owner_pid="${BASHPID:-$$}"
	if [[ -n "${AIDEVOPS_PULSE_BENIGN_BLOCKS_FILE:-}" ]]; then
		ledger_file="$AIDEVOPS_PULSE_BENIGN_BLOCKS_FILE"
	else
		ledger_managed_by_dispatch="1"
		[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || owner_pid="$$"
		if ! _dispatch_prepare_benign_blocks_scratch_dir; then
			printf 'Failed to prepare benign block ledger scratch directory: %s\n' "${HOME}/.aidevops/logs/.pulse-dispatch-benign-blocks" >&2
		else
			ledger_file=$(mktemp "${_DISPATCH_BENIGN_BLOCKS_SCRATCH_DIR}/benign-blocks.${owner_pid}.XXXXXX" 2>/dev/null || printf '%s\n' "${_DISPATCH_BENIGN_BLOCKS_SCRATCH_DIR}/benign-blocks.${owner_pid}.${RANDOM}")
		fi
	fi
	if [[ -z "$ledger_file" ]]; then
		printf 'Failed to resolve benign block ledger file path\n' >&2
		_DISPATCH_BENIGN_BLOCKS_FILE=""
		_DISPATCH_BENIGN_BLOCKS_FILE_OWNED="0"
		return 0
	fi
	if [[ "$ledger_managed_by_dispatch" == "0" && "$ledger_file" == */* ]]; then
		local parent_dir
		parent_dir="${ledger_file%/*}"
		if [[ -n "$parent_dir" ]] && ! mkdir -p -- "$parent_dir"; then
			printf 'Failed to create benign block ledger parent directory: %s\n' "$parent_dir" >&2
		fi
	fi
	if ! : >"$ledger_file"; then
		printf 'Failed to initialize benign block ledger file: %s\n' "$ledger_file" >&2
	fi
	if [[ "$ledger_managed_by_dispatch" == "1" ]] && ! chmod 0600 "$ledger_file" 2>/dev/null; then
		printf 'Failed to secure benign block ledger file: %s\n' "$ledger_file" >&2
	fi
	_DISPATCH_BENIGN_BLOCKS_FILE="$ledger_file"
	_DISPATCH_BENIGN_BLOCKS_FILE_OWNED="$ledger_managed_by_dispatch"
	export _DISPATCH_BENIGN_BLOCKS_FILE
	printf '%s\n' "$_DISPATCH_BENIGN_BLOCKS_FILE"
	return 0
}

#######################################
# Remove the cycle-local benign block ledger once the dispatch loop has read it.
#
# Returns: 0 always
#######################################
_dispatch_cleanup_benign_blocks_cycle() {
	local ledger_file="${_DISPATCH_BENIGN_BLOCKS_FILE:-}"
	local ledger_owned="${_DISPATCH_BENIGN_BLOCKS_FILE_OWNED:-0}"
	if [[ -n "$ledger_file" && "$ledger_owned" == "1" ]] && ! rm -f "$ledger_file"; then
		printf 'Failed to remove benign block ledger file: %s\n' "$ledger_file" >&2
	fi
	_DISPATCH_BENIGN_BLOCKS_FILE=""
	_DISPATCH_BENIGN_BLOCKS_FILE_OWNED="0"
	return 0
}

#######################################
# Return the current cycle-local benign block ledger path, creating a default
# when the orchestrator has not explicitly started a ledger.
#
# Stdout: file path
# Returns: 0 always
#######################################
_dispatch_benign_blocks_file() {
	if [[ -z "${_DISPATCH_BENIGN_BLOCKS_FILE:-}" ]]; then
		_dispatch_begin_benign_blocks_cycle >/dev/null
	fi
	printf '%s\n' "$_DISPATCH_BENIGN_BLOCKS_FILE"
	return 0
}

#######################################
# Record a candidate that hit a benign dispatch block in the current pulse.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - benign reason token
# Returns: 0 always
#######################################
_dispatch_mark_benign_blocked_candidate() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local ledger_file
	ledger_file=$(_dispatch_benign_blocks_file)
	mkdir -p "${ledger_file%/*}" 2>/dev/null || true
	printf '%s\t%s\t%s\n' "$issue_number" "$repo_slug" "$reason" >>"$ledger_file" 2>/dev/null || true
	return 0
}

#######################################
# Check whether a candidate already hit a benign dispatch block this pulse.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Stdout: benign reason token when present
# Returns:
#   0 - candidate is blocked for this pulse
#   1 - candidate is not blocked
#######################################
_dispatch_benign_blocked_candidate_reason() {
	local issue_number="$1"
	local repo_slug="$2"
	local ledger_file
	local reason=""
	ledger_file=$(_dispatch_benign_blocks_file)
	[[ -f "$ledger_file" ]] || return 1
	reason=$(awk -F '\t' -v issue="$issue_number" -v repo="$repo_slug" '
		$1 == issue && $2 == repo { reason = $3 }
		END { if (reason != "") { print reason } }
	' "$ledger_file" 2>/dev/null) || return 1
	[[ -n "$reason" ]] || return 1
	printf '%s\n' "$reason"
	return 0
}

#######################################
# Run a dispatch candidate under the stage watchdog while preserving benign
# block return codes without emitting generic Stage failed noise.
#
# Arguments:
#   $1 - file path where the raw dispatch rc should be written
#   $2.. - command and arguments to execute
# Returns:
#   0 for success or benign expected block rc=3; otherwise the command rc.
#######################################
_dispatch_stage_rc_adapter() {
	local rc_file="$1"
	shift

	local raw_rc=0
	"$@" || raw_rc=$?
	if ! printf '%s\n' "$raw_rc" >"$rc_file"; then
		printf 'Failed to write dispatch rc to %s\n' "$rc_file" >&2
		return "$raw_rc"
	fi
	if [[ "$raw_rc" -eq 3 ]]; then
		return 0
	fi
	return "$raw_rc"
}

#######################################
# Set a pulse-stats gauge when the stats helper is loaded.
#
# Arguments:
#   $1 - gauge name
#   $2 - integer value
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_gauge() {
	local gauge_name="$1"
	local gauge_value="${2:-0}"
	if declare -F pulse_stats_set_gauge >/dev/null 2>&1; then
		pulse_stats_set_gauge "$gauge_name" "$gauge_value" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Count recent worker failure/rate-limit metrics for launch pacing.
#
# Stdout: "<failures> <rate_limits>".
#######################################
_dispatch_recent_worker_pressure_counts() {
	local failure_override="${PULSE_DISPATCH_STAGGER_RECENT_FAILURES:-}"
	local rate_limit_override="${PULSE_DISPATCH_STAGGER_RECENT_RATE_LIMITS:-}"
	if [[ "$failure_override" =~ ^[0-9]+$ || "$rate_limit_override" =~ ^[0-9]+$ ]]; then
		[[ "$failure_override" =~ ^[0-9]+$ ]] || failure_override=0
		[[ "$rate_limit_override" =~ ^[0-9]+$ ]] || rate_limit_override=0
		printf '%s %s\n' "$failure_override" "$rate_limit_override"
		return 0
	fi

	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_limit="${AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT:-2000}"
	local ttl_seconds="${PULSE_DISPATCH_STAGGER_FAILURE_WINDOW_SECONDS:-900}"
	local health_helper="${_PULSE_DISPATCH_LIB_DIR}/worker-terminal-health.py"
	[[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=900
	[[ "$evidence_limit" =~ ^[1-9][0-9]*$ ]] || evidence_limit=2000
	[[ -f "$metrics_file" ]] || { printf '0 0\n'; return 0; }
	local health_counts="" successes="" failures="" rate_limits="" service_interruptions="" provider_5xx="" progress=""
	health_counts=$(python3 "$health_helper" "$metrics_file" "$evidence_file" "$ttl_seconds" "$evidence_limit") || health_counts="0 3 0 0 0 0"
	read -r successes failures rate_limits service_interruptions provider_5xx progress <<<"$health_counts"
	printf '%s %s\n' "$failures" "$rate_limits"
	return 0
}

#######################################
# Return cached GraphQL remaining budget for launch pacing.
#
# Stdout: integer remaining budget, or blank when unavailable.
#######################################
_dispatch_graphql_remaining_cached() {
	if [[ -n "${PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING:-}" ]]; then
		printf '%s\n' "$PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING"
		return 0
	fi
	if [[ -n "${_DISPATCH_STAGGER_GRAPHQL_REMAINING:-}" ]]; then
		printf '%s\n' "$_DISPATCH_STAGGER_GRAPHQL_REMAINING"
		return 0
	fi
	_DISPATCH_STAGGER_GRAPHQL_REMAINING=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null || printf '\n')
	printf '%s\n' "$_DISPATCH_STAGGER_GRAPHQL_REMAINING"
	return 0
}

_dispatch_failure_pressure_points() {
	local recent_failures="$1"
	[[ "$recent_failures" =~ ^[0-9]+$ ]] || recent_failures=0
	if ((recent_failures >= 3)); then
		printf '4\n'
		return 0
	fi
	if ((recent_failures >= 1)); then
		printf '2\n'
		return 0
	fi
	printf '0\n'
	return 0
}

_dispatch_provider_pressure_points() {
	local recent_rate_limits="$1"
	local provider_backoff_active="${PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE:-0}"
	[[ "$recent_rate_limits" =~ ^[0-9]+$ ]] || recent_rate_limits=0
	if [[ "$provider_backoff_active" == "1" || "$recent_rate_limits" -gt 0 || -f "${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}" ]]; then
		printf '6\n'
		return 0
	fi
	printf '0\n'
	return 0
}

_dispatch_graphql_pressure_points() {
	local graphql_remaining="" graphql_low="" graphql_critical=""
	graphql_remaining=$(_dispatch_graphql_remaining_cached)
	graphql_low="${PULSE_DISPATCH_STAGGER_GRAPHQL_LOW:-1250}"
	graphql_critical="${PULSE_DISPATCH_STAGGER_GRAPHQL_CRITICAL:-750}"
	[[ "$graphql_low" =~ ^[0-9]+$ ]] || graphql_low=1250
	[[ "$graphql_critical" =~ ^[0-9]+$ ]] || graphql_critical=750
	if [[ "$graphql_remaining" =~ ^[0-9]+$ ]]; then
		if ((graphql_remaining < graphql_critical)); then
			printf '4\n'
			return 0
		fi
		if ((graphql_remaining < graphql_low)); then
			printf '2\n'
			return 0
		fi
	fi
	printf '0\n'
	return 0
}

_dispatch_finalize_stagger_delay() {
	local pressure_points="$1"
	local launches_so_far="$2"
	local candidate_index="$3"
	local candidate_json="$4"
	[[ "$pressure_points" =~ ^[0-9]+$ ]] || pressure_points=0
	if ((pressure_points <= 0)); then
		printf '0\n'
		return 0
	fi
	local issue_number="" jitter_max="" jitter="" delay="" cap=""
	issue_number=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
	[[ "$issue_number" =~ ^[0-9]+$ ]] || issue_number=0
	jitter_max="${PULSE_DISPATCH_STAGGER_JITTER_MAX_SECONDS:-3}"
	cap="${PULSE_DISPATCH_STAGGER_MAX_SECONDS:-20}"
	[[ "$jitter_max" =~ ^[0-9]+$ ]] || jitter_max=3
	[[ "$cap" =~ ^[0-9]+$ ]] || cap=20
	jitter=0
	if ((jitter_max > 0)); then
		jitter=$(((issue_number + candidate_index + launches_so_far) % (jitter_max + 1)))
	fi
	delay=$((pressure_points + jitter))
	((delay > cap)) && delay="$cap"
	_dispatch_stats_gauge "dispatch_inter_launch_delay_seconds" "$delay"
	printf '%d\n' "$delay"
	return 0
}

#######################################
# Compute adaptive inter-launch delay for parallel worker dispatch.
#
# Arguments:
#   $1 - launches already started in this round
#   $2 - candidate index in this loop
#   $3 - candidate JSON
#   $4 - max parallelism for this round
# Stdout: integer seconds to sleep before launching this candidate.
#######################################
_dispatch_inter_launch_delay() {
	local launches_so_far="${1:-0}"
	local candidate_index="${2:-0}"
	local candidate_json="${3:-}"
	local max_parallel="${4:-1}"
	[[ "$launches_so_far" =~ ^[0-9]+$ ]] || launches_so_far=0
	[[ "$candidate_index" =~ ^[0-9]+$ ]] || candidate_index=0
	[[ "$max_parallel" =~ ^[0-9]+$ ]] || max_parallel=1
	if [[ "${PULSE_DISPATCH_STAGGER_ADAPTIVE:-1}" == "0" || "$launches_so_far" -eq 0 ]]; then
		printf '0\n'
		return 0
	fi

	local pressure_points=0
	local recent_failures="" recent_rate_limits="" pressure_line=""
	pressure_line=$(_dispatch_recent_worker_pressure_counts)
	read -r recent_failures recent_rate_limits <<<"$pressure_line"
	[[ "$recent_failures" =~ ^[0-9]+$ ]] || recent_failures=0
	[[ "$recent_rate_limits" =~ ^[0-9]+$ ]] || recent_rate_limits=0
	pressure_points=$((pressure_points + $(_dispatch_failure_pressure_points "$recent_failures")))
	pressure_points=$((pressure_points + $(_dispatch_provider_pressure_points "$recent_rate_limits")))
	pressure_points=$((pressure_points + $(_dispatch_graphql_pressure_points)))

	if ((max_parallel >= 4 && launches_so_far >= 4 && pressure_points > 0)); then
		pressure_points=$((pressure_points + 1))
	fi
	_dispatch_finalize_stagger_delay "$pressure_points" "$launches_so_far" "$candidate_index" "$candidate_json"
	return 0
}

_dispatch_ramp_now() {
	if [[ "${AIDEVOPS_PULSE_DISPATCH_RAMP_NOW:-}" =~ ^[0-9]+$ ]]; then
		printf '%s' "$AIDEVOPS_PULSE_DISPATCH_RAMP_NOW"
		return 0
	fi
	date +%s
	return 0
}

_dispatch_ramp_system_boot_ts() {
	local boot_ts="${1:-}"
	if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
		printf '%s' "$boot_ts"
		return 0
	fi
	if declare -F _gh_secondary_system_boot_ts >/dev/null 2>&1; then
		boot_ts="$(_gh_secondary_system_boot_ts 2>/dev/null || true)"
		if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
			printf '%s' "$boot_ts"
			return 0
		fi
	fi
	if [[ -r /proc/stat ]]; then
		boot_ts=$(sed -nE 's/^btime[[:space:]]+([0-9]+).*/\1/p' /proc/stat 2>/dev/null | sed -n '1p')
		if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
			printf '%s' "$boot_ts"
			return 0
		fi
	fi
	if command -v sysctl >/dev/null 2>&1; then
		boot_ts=$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/.*sec = ([0-9]+).*/\1/p' | sed -n '1p')
		if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
			printf '%s' "$boot_ts"
			return 0
		fi
	fi
	return 1
}

_dispatch_ramp_cooldown_expires_at() {
	local expires="${1:-}"
	local file="${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE:-${HOME}/.aidevops/cache/gh-secondary-cooldown.json}"
	if [[ "$expires" =~ ^[0-9]+$ ]]; then
		printf '%s' "$expires"
		return 0
	fi
	if declare -F _gh_secondary_cooldown_expires_at >/dev/null 2>&1; then
		expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
		if [[ "$expires" =~ ^[0-9]+$ ]]; then
			printf '%s' "$expires"
			return 0
		fi
	fi
	[[ -f "$file" ]] || return 1
	if command -v jq >/dev/null 2>&1; then
		expires=$(jq -r '.expires_at // 0' "$file" 2>/dev/null || true)
	else
		expires=$(sed -nE 's/.*"expires_at"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$file" | sed -n '1p')
	fi
	if [[ "$expires" =~ ^[0-9]+$ ]]; then
		printf '%s' "$expires"
		return 0
	fi
	return 1
}

_dispatch_ramp_phase_start() {
	local now=""
	local boot_ts="${1:-}"
	local expires="${2:-}"
	local boot_secs="${AIDEVOPS_PULSE_DISPATCH_RAMP_BOOT_SECS:-${AIDEVOPS_GH_READ_RAMP_BOOT_SECS:-180}}"
	local recovery_secs="${AIDEVOPS_PULSE_DISPATCH_RAMP_RECOVERY_SECS:-${AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS:-300}}"
	if [[ "${AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH:-}" =~ ^[0-9]+$ ]]; then
		printf '%s %s\n' "${AIDEVOPS_PULSE_DISPATCH_RAMP_PHASE:-manual}" "$AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH"
		return 0
	fi
	now="$(_dispatch_ramp_now)"
	if [[ "$boot_secs" =~ ^[0-9]+$ && "$boot_secs" -gt 0 ]]; then
		if [[ ! "$boot_ts" =~ ^[0-9]+$ ]]; then
			boot_ts="$(_dispatch_ramp_system_boot_ts "" 2>/dev/null || true)"
		fi
		if [[ "$boot_ts" =~ ^[0-9]+$ && "$now" -ge "$boot_ts" && $((now - boot_ts)) -lt "$boot_secs" ]]; then
			printf 'boot %s\n' "$boot_ts"
			return 0
		fi
	fi
	if [[ "$recovery_secs" =~ ^[0-9]+$ && "$recovery_secs" -gt 0 ]]; then
		if [[ ! "$expires" =~ ^[0-9]+$ ]]; then
			expires="$(_dispatch_ramp_cooldown_expires_at "" 2>/dev/null || true)"
		fi
		if [[ "$expires" =~ ^[0-9]+$ && "$now" -ge "$expires" && $((now - expires)) -lt "$recovery_secs" ]]; then
			printf 'cooldown-recovery %s\n' "$expires"
			return 0
		fi
	fi
	return 1
}

_dispatch_apply_startup_capacity_ramp() {
	local max_workers="$1"
	local active_workers="$2"
	local slot_secs="${AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS:-120}"
	local boot_ts="${3:-}"
	local expires="${4:-}"
	local now=""
	local phase_line=""
	local phase=""
	local start_ts=""
	local elapsed=0
	local ramp_cap=1
	[[ "${AIDEVOPS_PULSE_DISPATCH_RAMP_ENABLED:-1}" == "1" ]] || {
		printf '%s\n' "$max_workers"
		return 0
	}
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$slot_secs" =~ ^[0-9]+$ && "$slot_secs" -gt 0 ]] || slot_secs=120
	phase_line="$(_dispatch_ramp_phase_start "$boot_ts" "$expires" 2>/dev/null || true)"
	[[ -n "$phase_line" ]] || {
		printf '%s\n' "$max_workers"
		return 0
	}
	read -r phase start_ts <<<"$phase_line"
	[[ "$start_ts" =~ ^[0-9]+$ ]] || {
		printf '%s\n' "$max_workers"
		return 0
	}
	now="$(_dispatch_ramp_now)"
	if [[ "$now" =~ ^[0-9]+$ && "$now" -ge "$start_ts" ]]; then
		elapsed=$((now - start_ts))
	fi
	ramp_cap=$((1 + (elapsed / slot_secs)))
	((ramp_cap < 1)) && ramp_cap=1
	if ((ramp_cap < max_workers)); then
		echo "[pulse-wrapper] Dispatch_ramp active: phase=${phase} cap=${ramp_cap} max_workers=${max_workers} active=${active_workers} step_seconds=${slot_secs}" >>"${LOGFILE:-/dev/null}"
		printf '%s\n' "$ramp_cap"
		return 0
	fi
	printf '%s\n' "$max_workers"
	return 0
}

#######################################
# Compute the dispatch capacity for this round.
#
# Stdout: "<max_workers> <active_workers> <available_slots>" on success.
# Returns:
#   0 - capacity computed (caller checks available_slots > 0 before dispatch)
#   1 - stop flag present; caller should short-circuit
#######################################
