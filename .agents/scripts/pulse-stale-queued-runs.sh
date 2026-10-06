#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-stale-queued-runs.sh - cancel GitHub Actions runs queued past a max age (GH#33602)
#
# GitHub can keep workflow runs in `queued` indefinitely. Those ghosts inflate
# `?status=queued` counts (Actions queue saturation check, runner broker
# health) and make idle runner pools look backlogged. This pulse stage, per
# pulse-managed repo and at most once per interval:
#
#   1. lists `actions/runs?status=queued&created=<cutoff` (one REST page);
#   2. keeps only runs queued for at least the max age (the later of
#      created_at and run_started_at, so fresh re-runs are never touched);
#   3. POSTs `cancel`; on HTTP 409, or when a previous accepted cancel had no
#      effect by the next pass, POSTs `force-cancel`;
#   4. logs runs GitHub refuses to cancel (409 on both) once per run ID and
#      leaves them alone unless AIDEVOPS_STALE_QUEUED_RUN_DELETE=1, which
#      allows `DELETE /actions/runs/{id}`.
#
# API errors are classified (rate_limit/permission/conflict/not_found/other)
# and never echoed raw into logs.
#
# Usage:
#   pulse-stale-queued-runs.sh scan [--repos-json PATH] [--repo OWNER/REPO] [--dry-run] [--force]
#
# Settings (environment):
#   AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS   default 8; 0 disables the stage
#   AIDEVOPS_STALE_QUEUED_RUN_DELETE          1 = delete unkillable 409 ghosts (default 0)
#   AIDEVOPS_STALE_QUEUED_RUN_INTERVAL_SECONDS per-repo cadence (default 3600)
#   AIDEVOPS_STALE_QUEUED_RUN_MAX_PER_REPO    max runs acted on per repo pass (default 20)
#   AIDEVOPS_STALE_QUEUED_RUN_MAX_REPOS       max repos per pass (default 50)
#   AIDEVOPS_STALE_QUEUED_RUN_CORE_RESERVE    REST core calls to leave untouched (default 500)
#   AIDEVOPS_STALE_QUEUED_RUN_STATE_DIR       state dir (default ${PULSE_DIR}/stale-queued-runs)

set -uo pipefail

_SQR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
if [[ -f "${_SQR_SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck disable=SC1091
	source "${_SQR_SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true
fi

SQR_REPOS_JSON="${AIDEVOPS_STALE_QUEUED_RUN_REPOS_JSON:-${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"
SQR_STATE_DIR="${AIDEVOPS_STALE_QUEUED_RUN_STATE_DIR:-${PULSE_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}/stale-queued-runs}"
SQR_GRAPHQL_BREAKER_STATE="${AIDEVOPS_STALE_QUEUED_RUN_BREAKER_STATE:-${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state}"
SQR_BREAKER_FRESH_SECONDS=3600
SQR_NOACCESS_SECONDS=86400
SQR_PAGE_SIZE=100
_SQR_RATE_LIMIT_RC=75
_SQR_STOP_REPO_RC=2
_SQR_DRY_RUN_TAG="DRY_RUN"

_sqr_log() {
	local message="$1"
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[pulse-stale-queued-runs] %s\n' "$message" >>"$LOGFILE" 2>/dev/null || true
	else
		printf '[pulse-stale-queued-runs] %s\n' "$message" >&2
	fi
	return 0
}

_sqr_uint_or_default() {
	local value="$1"
	local fallback="$2"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$((10#$value))"
	else
		printf '%s\n' "$fallback"
	fi
	return 0
}

_sqr_max_age_hours() {
	_sqr_uint_or_default "${AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS:-8}" 8
	return 0
}

_sqr_now_epoch() {
	date -u '+%s'
	return 0
}

_sqr_epoch_to_iso() {
	local epoch="$1"
	local iso=""
	iso=$(date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
	[[ -n "$iso" ]] || iso=$(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
	[[ -n "$iso" ]] || return 1
	printf '%s\n' "$iso"
	return 0
}

_sqr_slug_key() {
	local repo_slug="$1"
	printf '%s\n' "$repo_slug" | tr '/:' '__'
	return 0
}

_sqr_file_epoch() {
	local file="$1"
	local value=""
	[[ -f "$file" ]] || return 1
	value=$(<"$file")
	[[ "$value" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$value"
	return 0
}

#######################################
# Return 0 when the repo has not been scanned within the configured interval.
#######################################
_sqr_repo_due() {
	local repo_slug="$1"
	local now="$2"
	local interval=""
	local last=""
	local key=""
	interval=$(_sqr_uint_or_default "${AIDEVOPS_STALE_QUEUED_RUN_INTERVAL_SECONDS:-3600}" 3600)
	key=$(_sqr_slug_key "$repo_slug")
	last=$(_sqr_file_epoch "${SQR_STATE_DIR}/${key}.last") || return 0
	[[ $((now - last)) -ge "$interval" ]]
	return $?
}

_sqr_mark_scanned() {
	local repo_slug="$1"
	local now="$2"
	local key=""
	key=$(_sqr_slug_key "$repo_slug")
	mkdir -p "$SQR_STATE_DIR" 2>/dev/null || return 0
	printf '%s\n' "$now" >"${SQR_STATE_DIR}/${key}.last" 2>/dev/null || true
	return 0
}

#######################################
# Per-run state: "<run_id>\t<state>\t<epoch>" lines. States: cancel_requested,
# force_cancel_requested, ghost, deleted, delete_failed.
#######################################
_sqr_state_get() {
	local state_file="$1"
	local run_id="$2"
	[[ -f "$state_file" ]] || return 0
	awk -F '\t' -v id="$run_id" '$1 == id { state = $2 } END { if (state != "") print state }' "$state_file" 2>/dev/null
	return 0
}

_sqr_state_set() {
	local state_file="$1"
	local run_id="$2"
	local state="$3"
	local now="$4"
	local tmp_file=""
	mkdir -p "$SQR_STATE_DIR" 2>/dev/null || return 0
	tmp_file=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || return 0
	if [[ -f "$state_file" ]]; then
		awk -F '\t' -v id="$run_id" '$1 != id' "$state_file" >"$tmp_file" 2>/dev/null || true
	fi
	printf '%s\t%s\t%s\n' "$run_id" "$state" "$now" >>"$tmp_file"
	mv -f "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file"
	return 0
}

# Drop state for runs no longer listed as stale and queued (cancelled, deleted
# or completed). Only called after a complete listing.
_sqr_state_prune() {
	local state_file="$1"
	local current_ids="$2"
	local tmp_file=""
	[[ -f "$state_file" ]] || return 0
	tmp_file=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || return 0
	awk -F '\t' -v ids="$current_ids" 'BEGIN { n = split(ids, list, " "); for (i = 1; i <= n; i++) keep[list[i]] = 1 } ($1 in keep)' \
		"$state_file" >"$tmp_file" 2>/dev/null || true
	mv -f "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file"
	return 0
}

#######################################
# Classify gh stderr without echoing it (redacted API style).
#######################################
_sqr_classify_error() {
	local error_text="$1"
	local normalized=""
	normalized=$(printf '%s' "$error_text" | tr '[:upper:]' '[:lower:]')
	case "$normalized" in
	*"rate limit"* | *"abuse detection"* | *"temporarily blocked"*) printf 'rate_limit\n' ;;
	*"http 409"*) printf 'conflict\n' ;;
	*"http 401"* | *"http 403"* | *"resource not accessible"* | *forbidden*) printf 'permission\n' ;;
	*"http 404"*) printf 'not_found\n' ;;
	*) printf 'other\n' ;;
	esac
	return 0
}

#######################################
# Run a write call. Stdout: ok | rate_limit | conflict | permission | not_found | other
#######################################
_sqr_api_write() {
	local method="$1"
	local endpoint="$2"
	local error_file=""
	local error_text=""
	error_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/stale-queued-run-api.XXXXXX") || {
		printf 'other\n'
		return 0
	}
	if AIDEVOPS_GH_ROUTE_DECISION="pulse-stale-queued-runs-write-rest" \
		gh api -X "$method" "$endpoint" --silent >/dev/null 2>"$error_file"; then
		rm -f "$error_file"
		printf 'ok\n'
		return 0
	fi
	error_text=$(<"$error_file")
	rm -f "$error_file"
	_sqr_classify_error "$error_text"
	return 0
}

#######################################
# Budget gate: respect the GraphQL/REST circuit breaker state left by the
# pulse and keep a REST core reserve. Side-effect free (no breaker trips).
#######################################
_sqr_budget_allows() {
	local repo_count="$1"
	local now="$2"
	local reserve=""
	local per_repo=""
	local remaining=""
	local tripped_at=""
	local rest_class="${AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS:-}"

	case "$rest_class" in
	reserve | emergency)
		_sqr_log "REST core budget class '${rest_class}'; skipping"
		return 1
		;;
	esac
	if [[ -f "$SQR_GRAPHQL_BREAKER_STATE" ]]; then
		tripped_at=$(awk 'NR == 1 { print $1 }' "$SQR_GRAPHQL_BREAKER_STATE" 2>/dev/null || true)
		if [[ "$tripped_at" =~ ^[0-9]+$ && $((now - tripped_at)) -lt "$SQR_BREAKER_FRESH_SECONDS" ]]; then
			_sqr_log "rate-limit circuit breaker tripped recently; skipping"
			return 1
		fi
	fi

	reserve=$(_sqr_uint_or_default "${AIDEVOPS_STALE_QUEUED_RUN_CORE_RESERVE:-500}" 500)
	per_repo=$(_sqr_uint_or_default "${AIDEVOPS_STALE_QUEUED_RUN_MAX_PER_REPO:-20}" 20)
	remaining=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-stale-queued-runs-core-budget-rest" \
		gh api rate_limit --jq '.resources.core.remaining // empty' 2>/dev/null) || remaining=""
	if [[ ! "$remaining" =~ ^[0-9]+$ ]]; then
		_sqr_log "REST core budget unknown; skipping"
		return 1
	fi
	# Worst case: list + permission + (cancel, force-cancel, delete) per run.
	local required=$((reserve + repo_count * (2 + per_repo * 3)))
	if [[ "$remaining" -lt "$required" ]]; then
		_sqr_log "REST core budget insufficient: remaining=${remaining}, required=${required}; skipping"
		return 1
	fi
	return 0
}

_sqr_list_repos() {
	local repos_json="$1"
	[[ -f "$repos_json" ]] || return 1
	jq -r '
		.initialized_repos[]?
		| select(.maintenance != false)
		| select((.pulse // false) == true)
		| select((.local_only // false) == false)
		| select(.stale_queued_run_watchdog != false)
		| select((.role // "maintainer") != "contributor")
		| select((.slug // "") != "")
		| .slug
	' "$repos_json" 2>/dev/null
	return $?
}

#######################################
# List stale queued runs. Stdout line 1: "complete=<0|1>", then TSV rows
# "<run_id>\t<workflow>\t<age_hours>" for runs queued >= max age.
# Returns 0 ok, 75 rate limit, 2 permission, 1 other failure.
#######################################
_sqr_list_stale_runs() {
	local repo_slug="$1"
	local now="$2"
	local max_age_s="$3"
	local endpoint="repos/${repo_slug}/actions/runs?status=queued&exclude_pull_requests=true&per_page=${SQR_PAGE_SIZE}"
	local cutoff=""
	local error_file=""
	local runs_json=""
	local error_class=""
	cutoff=$(_sqr_epoch_to_iso "$((now - max_age_s))") && endpoint="${endpoint}&created=%3C${cutoff}"
	error_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/stale-queued-run-list.XXXXXX") || return 1
	if ! runs_json=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-stale-queued-runs-list-rest" gh api "$endpoint" 2>"$error_file"); then
		error_class=$(_sqr_classify_error "$(<"$error_file")")
		rm -f "$error_file"
		case "$error_class" in
		rate_limit) return "$_SQR_RATE_LIMIT_RC" ;;
		permission | not_found) return "$_SQR_STOP_REPO_RC" ;;
		esac
		return 1
	fi
	rm -f "$error_file"
	printf '%s' "$runs_json" | jq -r --argjson now "$now" --argjson max_age "$max_age_s" --argjson page "$SQR_PAGE_SIZE" '
		"complete=" + (if ((.total_count // 0) <= $page) then "1" else "0" end),
		(.workflow_runs[]?
			| select(.status == "queued")
			| ([.created_at, .run_started_at]
				| map(select(type == "string") | (try fromdateiso8601 catch null))
				| map(select(. != null))
				| max) as $since
			| select($since != null and ($now - $since) >= $max_age)
			| [(.id | tostring),
				((.name // .display_title // "unknown") | tostring | gsub("[\t\r\n]"; " ")),
				((($now - $since) / 3600) | floor | tostring)]
			| @tsv)
	' 2>/dev/null
	return $?
}

#######################################
# Return 0 when the token can write Actions for the repo (push/maintain/admin).
#######################################
_sqr_has_actions_write() {
	local repo_slug="$1"
	local allowed=""
	allowed=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-stale-queued-runs-permission-rest" \
		gh api "repos/${repo_slug}" --jq '(.permissions // {}) | ((.admin // false) or (.maintain // false) or (.push // false))' 2>/dev/null) || return 1
	[[ "$allowed" == "true" ]]
	return $?
}

_sqr_run_desc() {
	local repo_slug="$1"
	local run_id="$2"
	local workflow="$3"
	local age_h="$4"
	printf 'repo=%s run_id=%s workflow="%s" age_h=%s' "$repo_slug" "$run_id" "$workflow" "$age_h"
	return 0
}

# Map a non-ok write outcome to a return code; logs the failure.
_sqr_write_failure_rc() {
	local outcome="$1"
	local action="$2"
	local desc="$3"
	case "$outcome" in
	rate_limit)
		_sqr_log "${action} hit rate limit: ${desc}"
		return "$_SQR_RATE_LIMIT_RC"
		;;
	permission)
		_sqr_log "${action} denied (no Actions write access): ${desc}"
		return "$_SQR_STOP_REPO_RC"
		;;
	not_found)
		_sqr_log "${action}: run no longer exists: ${desc}"
		return 0
		;;
	esac
	_sqr_log "${action} failed (${outcome}): ${desc}"
	return 0
}

#######################################
# Unkillable ghost: log once per run ID; delete only with explicit opt-in.
#######################################
_sqr_handle_ghost() {
	local repo_slug="$1"
	local run_id="$2"
	local desc="$3"
	local prev_state="$4"
	local state_file="$5"
	local now="$6"
	local outcome=""
	if [[ "$prev_state" != "ghost" ]]; then
		_sqr_log "unkillable ghost (GitHub refuses cancel and force-cancel): ${desc}; left alone unless AIDEVOPS_STALE_QUEUED_RUN_DELETE=1"
		_sqr_state_set "$state_file" "$run_id" "ghost" "$now"
	fi
	[[ "${AIDEVOPS_STALE_QUEUED_RUN_DELETE:-0}" == "1" ]] || return 0
	outcome=$(_sqr_api_write DELETE "repos/${repo_slug}/actions/runs/${run_id}")
	if [[ "$outcome" == "ok" || "$outcome" == "not_found" ]]; then
		_sqr_log "deleted ghost run: ${desc}"
		_sqr_state_set "$state_file" "$run_id" "deleted" "$now"
		return 0
	fi
	_sqr_state_set "$state_file" "$run_id" "delete_failed" "$now"
	_sqr_write_failure_rc "$outcome" "delete" "$desc"
	return $?
}

_sqr_force_cancel() {
	local repo_slug="$1"
	local run_id="$2"
	local desc="$3"
	local prev_state="$4"
	local state_file="$5"
	local now="$6"
	local outcome=""
	outcome=$(_sqr_api_write POST "repos/${repo_slug}/actions/runs/${run_id}/force-cancel")
	if [[ "$outcome" == "ok" ]]; then
		_sqr_log "force-cancelled: ${desc}"
		_sqr_state_set "$state_file" "$run_id" "force_cancel_requested" "$now"
		return 0
	fi
	if [[ "$outcome" == "conflict" ]]; then
		_sqr_handle_ghost "$repo_slug" "$run_id" "$desc" "$prev_state" "$state_file" "$now"
		return $?
	fi
	_sqr_write_failure_rc "$outcome" "force-cancel" "$desc"
	return $?
}

#######################################
# Act on one stale queued run according to its recorded state.
#######################################
_sqr_handle_run() {
	local repo_slug="$1"
	local run_id="$2"
	local workflow="$3"
	local age_h="$4"
	local state_file="$5"
	local now="$6"
	local dry_run="$7"
	local prev_state=""
	local desc=""
	local outcome=""
	desc=$(_sqr_run_desc "$repo_slug" "$run_id" "$workflow" "$age_h")
	prev_state=$(_sqr_state_get "$state_file" "$run_id")

	if [[ "$dry_run" == "1" ]]; then
		printf '%s stale queued run %s prior_state=%s\n' "$_SQR_DRY_RUN_TAG" "$desc" "${prev_state:-none}"
		return 0
	fi

	case "$prev_state" in
	deleted | delete_failed) return 0 ;;
	ghost | force_cancel_requested)
		# force_cancel_requested still queued after an interval = no effect.
		_sqr_handle_ghost "$repo_slug" "$run_id" "$desc" "$prev_state" "$state_file" "$now"
		return $?
		;;
	cancel_requested)
		_sqr_force_cancel "$repo_slug" "$run_id" "$desc" "$prev_state" "$state_file" "$now"
		return $?
		;;
	esac

	outcome=$(_sqr_api_write POST "repos/${repo_slug}/actions/runs/${run_id}/cancel")
	if [[ "$outcome" == "ok" ]]; then
		_sqr_log "cancelled: ${desc}"
		_sqr_state_set "$state_file" "$run_id" "cancel_requested" "$now"
		return 0
	fi
	if [[ "$outcome" == "conflict" ]]; then
		_sqr_force_cancel "$repo_slug" "$run_id" "$desc" "$prev_state" "$state_file" "$now"
		return $?
	fi
	_sqr_write_failure_rc "$outcome" "cancel" "$desc"
	return $?
}

_sqr_noaccess_recent() {
	local repo_slug="$1"
	local now="$2"
	local key=""
	local marked=""
	key=$(_sqr_slug_key "$repo_slug")
	marked=$(_sqr_file_epoch "${SQR_STATE_DIR}/${key}.noaccess") || return 1
	[[ $((now - marked)) -lt "$SQR_NOACCESS_SECONDS" ]]
	return $?
}

_sqr_mark_noaccess() {
	local repo_slug="$1"
	local now="$2"
	local key=""
	key=$(_sqr_slug_key "$repo_slug")
	mkdir -p "$SQR_STATE_DIR" 2>/dev/null || return 0
	printf '%s\n' "$now" >"${SQR_STATE_DIR}/${key}.noaccess" 2>/dev/null || true
	return 0
}

#######################################
# Scan one repo. Returns 75 when the caller should stop the fanout.
#######################################
stale_queued_runs_scan_repo() {
	local repo_slug="$1"
	local dry_run="${2:-0}"
	local now=""
	local max_age_h=""
	local listing=""
	local list_rc=0
	local complete=0
	local state_file=""
	local current_ids=""
	local max_per_repo=""
	local acted=0
	local stale_count=0
	local handle_rc=0
	local run_id workflow age_h

	max_age_h=$(_sqr_max_age_hours)
	[[ "$max_age_h" -gt 0 ]] || return 0
	now=$(_sqr_now_epoch)
	max_per_repo=$(_sqr_uint_or_default "${AIDEVOPS_STALE_QUEUED_RUN_MAX_PER_REPO:-20}" 20)
	state_file="${SQR_STATE_DIR}/$(_sqr_slug_key "$repo_slug").runs"

	listing=$(_sqr_list_stale_runs "$repo_slug" "$now" "$((max_age_h * 3600))")
	list_rc=$?
	if [[ "$list_rc" -eq "$_SQR_RATE_LIMIT_RC" ]]; then
		_sqr_log "rate limit while listing queued runs for ${repo_slug}"
		return "$_SQR_RATE_LIMIT_RC"
	fi
	[[ "$dry_run" == "1" ]] || _sqr_mark_scanned "$repo_slug" "$now"
	if [[ "$list_rc" -eq "$_SQR_STOP_REPO_RC" ]]; then
		_sqr_log "${repo_slug}: Actions runs not readable (permission/not found); skipping for 24h"
		[[ "$dry_run" == "1" ]] || _sqr_mark_noaccess "$repo_slug" "$now"
		return 0
	fi
	if [[ "$list_rc" -ne 0 ]]; then
		_sqr_log "unable to list queued runs for ${repo_slug} (rc=${list_rc}); skipping"
		return 0
	fi
	[[ "${listing%%$'\n'*}" == "complete=1" ]] && complete=1

	while IFS=$'\t' read -r run_id workflow age_h; do
		[[ "$run_id" =~ ^[0-9]+$ ]] || continue
		current_ids="${current_ids} ${run_id}"
		stale_count=$((stale_count + 1))
	done <<<"$listing"
	if [[ "$complete" -eq 1 && "$dry_run" != "1" ]]; then
		_sqr_state_prune "$state_file" "$current_ids"
	fi
	[[ "$stale_count" -gt 0 ]] || return 0

	if [[ "$dry_run" != "1" ]] && ! _sqr_has_actions_write "$repo_slug"; then
		_sqr_log "${repo_slug}: ${stale_count} stale queued run(s) but no Actions write access; skipping for 24h"
		_sqr_mark_noaccess "$repo_slug" "$now"
		return 0
	fi

	while IFS=$'\t' read -r run_id workflow age_h; do
		[[ "$run_id" =~ ^[0-9]+$ ]] || continue
		if [[ "$acted" -ge "$max_per_repo" ]]; then
			_sqr_log "${repo_slug}: per-repo limit (${max_per_repo}) reached; remainder next pass"
			break
		fi
		acted=$((acted + 1))
		_sqr_handle_run "$repo_slug" "$run_id" "$workflow" "$age_h" "$state_file" "$now" "$dry_run"
		handle_rc=$?
		[[ "$handle_rc" -eq "$_SQR_RATE_LIMIT_RC" ]] && return "$_SQR_RATE_LIMIT_RC"
		if [[ "$handle_rc" -eq "$_SQR_STOP_REPO_RC" ]]; then
			_sqr_mark_noaccess "$repo_slug" "$now"
			break
		fi
	done <<<"$listing"
	_sqr_log "${repo_slug}: stale_queued=${stale_count} processed=${acted} max_age_h=${max_age_h}"
	return 0
}

stale_queued_runs_scan_repos() {
	local repos_json="${1:-$SQR_REPOS_JSON}"
	local dry_run="${2:-0}"
	local only_repo="${3:-}"
	local force="${4:-0}"
	local max_age_h=""
	local max_repos=""
	local now=""
	local repo_rows=""
	local repo_slug=""
	local -a due_repos=()

	max_age_h=$(_sqr_max_age_hours)
	if [[ "$max_age_h" -eq 0 ]]; then
		return 0
	fi
	now=$(_sqr_now_epoch)
	max_repos=$(_sqr_uint_or_default "${AIDEVOPS_STALE_QUEUED_RUN_MAX_REPOS:-50}" 50)
	[[ "$max_repos" -gt 0 ]] || max_repos=50

	if [[ -n "$only_repo" ]]; then
		repo_rows="$only_repo"
	else
		if [[ ! -f "$repos_json" ]]; then
			_sqr_log "repos.json not found at ${repos_json}; skipping"
			return 0
		fi
		repo_rows=$(_sqr_list_repos "$repos_json") || {
			_sqr_log "unable to read managed repositories; skipping"
			return 0
		}
	fi

	while IFS= read -r repo_slug; do
		[[ "$repo_slug" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || continue
		[[ "${#due_repos[@]}" -lt "$max_repos" ]] || break
		if [[ "$dry_run" != "1" && "$force" != "1" ]]; then
			_sqr_repo_due "$repo_slug" "$now" || continue
			_sqr_noaccess_recent "$repo_slug" "$now" && continue
		fi
		due_repos+=("$repo_slug")
	done <<<"$repo_rows"
	[[ "${#due_repos[@]}" -gt 0 ]] || return 0
	_sqr_budget_allows "${#due_repos[@]}" "$now" || return 0

	for repo_slug in "${due_repos[@]}"; do
		stale_queued_runs_scan_repo "$repo_slug" "$dry_run"
		if [[ $? -eq "$_SQR_RATE_LIMIT_RC" ]]; then
			_sqr_log "stopping stale queued run fanout after rate-limit response"
			break
		fi
	done
	return 0
}

main() {
	local command="${1:-scan}"
	local repos_json="$SQR_REPOS_JSON"
	local dry_run=0
	local force=0
	local only_repo=""
	shift || true
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repos-json)
			repos_json="${2:-}"
			shift 2
			;;
		--repo)
			only_repo="${2:-}"
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		--force)
			force=1
			shift
			;;
		*)
			shift
			;;
		esac
	done

	case "$command" in
	scan)
		stale_queued_runs_scan_repos "$repos_json" "$dry_run" "$only_repo" "$force"
		;;
	*)
		printf 'Usage: pulse-stale-queued-runs.sh scan [--repos-json PATH] [--repo OWNER/REPO] [--dry-run] [--force]\n' >&2
		return 2
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
