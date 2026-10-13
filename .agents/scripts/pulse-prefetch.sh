#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-prefetch.sh — Pre-flight state gathering orchestrator.
#
# Orchestrator that sources focused prefetch sub-libraries. Most function
# implementations live in the sub-libraries; prefetch_state remains here to
# preserve the existing function-complexity identity key while staying under
# the 500-line orchestrator target.
#
# Split from the Phase 7 monolith and completed for GH#18400/t1987.

[[ -n "${_PULSE_PREFETCH_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_pp_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pp_path" == "${BASH_SOURCE[0]}" ]] && _pp_path="."
	SCRIPT_DIR="$(cd "$_pp_path" && pwd)"
	unset _pp_path
fi

# Source sub-libraries in dependency order.
# shellcheck source=./pulse-prefetch-infra.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-infra.sh"

# shellcheck source=./pulse-prefetch-fetch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-fetch.sh"

# shellcheck source=./pulse-prefetch-repo.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-repo.sh"

# shellcheck source=./pulse-prefetch-orchestration.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-orchestration.sh"

# shellcheck source=./pulse-prefetch-secondary.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-secondary.sh"


prefetch_state() {
	local repos_json="$REPOS_JSON"

	if [[ ! -f "$repos_json" ]]; then
		echo "[pulse-wrapper] repos.json not found at $repos_json — skipping prefetch" >>"$LOGFILE"
		echo "ERROR: repos.json not found" >"$STATE_FILE"
		return 1
	fi

	echo "[pulse-wrapper] Pre-fetching state for all pulse-enabled repos..." >>"$LOGFILE"

	# Extract pulse-enabled, non-local-only repos as slug|path|ph_start|ph_end|expires.
	# pulse_hours accepts object {"start":N,"end":N} and legacy array [N,N].
	# pulse_hours fields default to "" when absent; pulse_expires defaults to "".
	# Bash 3.2: no associative arrays — use pipe-delimited fields.
	local repo_entries_raw
	repo_entries_raw=$(jq -r '
		def pulse_hour_start:
			if (.pulse_hours | type) == "array" then .pulse_hours[0]
			else .pulse_hours.start
			end;
		def pulse_hour_end:
			if (.pulse_hours | type) == "array" then .pulse_hours[1]
			else .pulse_hours.end
			end;
		.initialized_repos[] |
		select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") |
		[
			.slug,
			.path,
			(if .pulse_hours then (pulse_hour_start | tostring) else "" end),
			(if .pulse_hours then (pulse_hour_end | tostring) else "" end),
			(.pulse_expires // "")
		] | join("|")
	' "$repos_json")

	# Filter repos through schedule check; build slug|path pairs for downstream use
	local repo_entries=""
	while IFS='|' read -r slug path ph_start ph_end expires; do
		[[ -n "$slug" ]] || continue
		if check_repo_pulse_schedule "$slug" "$ph_start" "$ph_end" "$expires" "$repos_json"; then
			if [[ -z "$repo_entries" ]]; then
				repo_entries="${slug}|${path}"
			else
				repo_entries="${repo_entries}"$'\n'"${slug}|${path}"
			fi
		fi
	done <<<"$repo_entries_raw"

	if [[ -z "$repo_entries" ]]; then
		echo "[pulse-wrapper] No pulse-enabled repos in schedule window" >>"$LOGFILE"
		echo "No pulse-enabled repos in schedule window in repos.json" >"$STATE_FILE"
		return 1
	fi

	# GH#27777: record only count + deterministic digest, never raw repo names.
	_prefetch_record_efficiency_population "$repo_entries"

	# GH#19963: Batch prefetch via org-level gh search (L3 cache layer).
	_prefetch_batch_refresh

	# GH#34527: use the cycle-clamped watchdog deadline, not independent caps
	# whose sum can exhaust every cycle before state/scope publication.
	local parallel_timeout=120 prefetch_rc=0
	parallel_timeout=$(_prefetch_remaining_seconds 120) || return 124

	# Temp dir for parallel fetches
	local tmpdir
	tmpdir=$(mktemp -d)

	# Launch parallel gh fetches for each repo
	local pids=()
	local idx=0
	while IFS='|' read -r slug path; do
		_prefetch_remaining_seconds 120 >/dev/null || {
			prefetch_rc=124
			break
		}
		(
			_prefetch_single_repo "$slug" "$path" "${tmpdir}/${idx}.txt"
		) &
		pids+=($!)
		idx=$((idx + 1))
	done <<<"$repo_entries"

	# Wait for all parallel fetches with a hard timeout (t1482).
	# Each repo does 3 gh API calls (pr list, pr list --state all, issue list).
	# GH#15060: Raised from 60s to 120s. With 13 repos and repos having 100+ PRs,
	# the GraphQL responses are large and rate limiting serializes parallel calls.
	# 60s caused silent timeouts producing "Open PRs (0)" on large backlogs.
	_wait_parallel_pids "$parallel_timeout" "${pids[@]}" || prefetch_rc=$?

	# Assemble state file in repo order
	_assemble_state_file "$tmpdir"

	# Clean up
	rm -rf "$tmpdir"

	# Persist the schedule-filtered worker code scope before optional helpers.
	# Cross-repo issue filing does not authorize code changes outside this scope.
	local scope_slugs
	scope_slugs=$(echo "$repo_entries" | cut -d'|' -f1 | grep . | paste -sd ',' -)
	export PULSE_SCOPE_REPOS="$scope_slugs"
	echo "$scope_slugs" >"$SCOPE_FILE"
	echo "[pulse-wrapper] PULSE_SCOPE_REPOS=${scope_slugs}" >>"$LOGFILE"
	if [[ "$prefetch_rc" -ne 0 ]]; then
		printf '\nWARNING: INCOMPLETE primary repo fetch — verify live state before decisions.\n' >>"$STATE_FILE"
		return "$prefetch_rc"
	fi

	# t1482: Sub-helpers that call external scripts (gh API, pr-salvage,
	# gh-failure-miner) get individual timeouts via run_cmd_with_timeout.
	# If a helper times out, the pulse proceeds without that section —
	# degraded but functional. Bound the whole optional tail too: even local
	# helpers can accumulate significant work across a large repo set.
	local secondary_timeout=0
	if [[ "${PULSE_STAGE_DEADLINE_EPOCH:-}" =~ ^[1-9][0-9]*$ ]]; then
		if secondary_timeout=$(_prefetch_remaining_seconds "${PRE_RUN_STAGE_TIMEOUT:-600}"); then
			run_cmd_with_timeout "$secondary_timeout" _append_prefetch_sub_helpers "$repo_entries" || {
				echo "[pulse-wrapper] Optional prefetch helpers did not complete within ${secondary_timeout}s — primary state and scope preserved (GH#34527)" >>"$LOGFILE"
			}
		else
			echo "[pulse-wrapper] Optional prefetch helpers deferred: stage publication reserve reached (GH#34527)" >>"$LOGFILE"
		fi
	else
		_append_prefetch_sub_helpers "$repo_entries"
	fi

	local repo_count
	repo_count=$(echo "$repo_entries" | wc -l | tr -d ' ')
	echo "[pulse-wrapper] Pre-fetched state for $repo_count repos → $STATE_FILE" >>"$LOGFILE"
	return 0
}
# shellcheck source=./pulse-prefetch-workers.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-workers.sh"
