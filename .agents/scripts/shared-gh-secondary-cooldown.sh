#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub secondary-rate-limit cooldown guard (GH#23605)
# =============================================================================
# Sourced by shared-gh-wrappers.sh. Provides a small shared state file that all
# gh wrapper call sites can consult before starting noncritical GitHub work.

[[ -n "${_SHARED_GH_SECONDARY_COOLDOWN_LOADED:-}" ]] && return 0
_SHARED_GH_SECONDARY_COOLDOWN_LOADED=1

: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS:=300}"
: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME:=${HOME:-/tmp/.aidevops-${USER:-uid-${UID:-unknown}}}}"
: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE:=${AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME}/.aidevops/cache/gh-secondary-cooldown.json}"
: "${AIDEVOPS_GH_READ_RAMP_ENABLED:=1}"
: "${AIDEVOPS_GH_READ_RAMP_BOOT_SECS:=180}"
: "${AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS:=300}"
: "${AIDEVOPS_GH_READ_RAMP_BUDGET:=60}"
: "${AIDEVOPS_GH_READ_RAMP_STATE_FILE:=${AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME}/.aidevops/cache/gh-read-ramp-state.tsv}"

_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE=0
_GH_SECONDARY_COOLDOWN_LOGGED_RAMP=0
_GH_SECONDARY_READ_OP="read"

_gh_secondary_cooldown_now() {
	date +%s
	return 0
}

_gh_secondary_cooldown_file() {
	printf '%s' "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}"
	return 0
}

_gh_secondary_cooldown_detect() {
	local text="$1"
	printf '%s' "$text" | grep -Eqi 'secondary rate limit|abuse detection mechanism|You have exceeded a secondary rate limit' || return 1
	return 0
}

_gh_secondary_cooldown_request_id() {
	local text="$1"
	local request_id=""
	request_id=$(printf '%s\n' "$text" | sed -nE 's/.*([Xx]-[Gg]it[Hh]ub-[Rr]equest-[Ii]d|request[_ -]?id)[=: ]+([A-Za-z0-9:-]+).*/\2/p' | sed -n '1p')
	printf '%s' "$request_id"
	return 0
}

_gh_secondary_cooldown_safe_value() {
	local value="$1"
	local max_len="${2:-120}"
	value=${value//$'\r'/ }
	value=${value//$'\n'/ }
	value=${value//$'\t'/ }
	if [[ "$max_len" =~ ^[0-9]+$ && "${#value}" -gt "$max_len" ]]; then
		value="${value:0:$max_len}"
	fi
	printf '%s' "$value"
	return 0
}

_gh_secondary_cooldown_safe_family() {
	local value="$1"
	local max_len="${2:-80}"
	value="${value##*/}"
	value="$(_gh_secondary_cooldown_safe_value "$value" "$max_len")"
	value=$(printf '%s' "$value" | tr -c 'A-Za-z0-9._:@+=,-' '_' 2>/dev/null || printf 'unknown')
	[[ -n "$value" ]] || value="unknown"
	printf '%s' "$value"
	return 0
}

_gh_secondary_cooldown_caller_family() {
	local i=1
	local src=""
	local base=""
	while [[ "$i" -lt "${#BASH_SOURCE[@]}" ]]; do
		src="${BASH_SOURCE[$i]:-}"
		base="${src##*/}"
		case "$base" in
		shared-gh-secondary-cooldown.sh | shared-gh-wrappers.sh | shared-constants.sh | bash | -bash | zsh | -zsh | "")
			i=$((i + 1))
			continue
			;;
		esac
		_gh_secondary_cooldown_safe_family "$base" 80
		return 0
	done
	printf 'unknown'
	return 0
}

_gh_secondary_cooldown_endpoint_family() {
	local endpoint="${AIDEVOPS_GH_COOLDOWN_ENDPOINT_FAMILY:-${AIDEVOPS_GH_API_POOL:-${AIDEVOPS_GH_ROUTE_DECISION:-unknown}}}"
	case "$endpoint" in
	graphql | rest | rest-core | rest-search | search-graphql | search-rest | other | unknown) ;;
	*) endpoint="unknown" ;;
	esac
	_gh_secondary_cooldown_safe_family "$endpoint" 80
	return 0
}

_gh_secondary_cooldown_body_classification() {
	local response_text="$1"
	local status="${2:-}"
	local remaining="${3:-}"
	if printf '%s' "$response_text" | grep -Eqi 'abuse detection mechanism'; then
		printf 'abuse-detection'
		return 0
	fi
	if printf '%s' "$response_text" | grep -Eqi 'secondary rate limit|You have exceeded a secondary rate limit'; then
		printf 'secondary-rate-limit'
		return 0
	fi
	if printf '%s' "$response_text" | grep -Eqi 'GraphQL: API rate limit already exceeded|API rate limit exceeded'; then
		printf 'primary-rate-limit'
		return 0
	fi
	if [[ "$remaining" =~ ^[0-9]+$ && "$remaining" -eq 0 ]]; then
		printf 'primary-rate-limit'
		return 0
	fi
	case "$status" in
	403)
		printf 'generic-forbidden'
		return 0
		;;
	429)
		printf 'rate-limit-message'
		return 0
		;;
	esac
	if [[ -z "${response_text//[[:space:]]/}" ]]; then
		printf 'empty-response'
		return 0
	fi
	printf 'other-error'
	return 0
}

_gh_secondary_cooldown_json_string() {
	local value="$1"
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	value=${value//$'\t'/\\t}
	printf '"%s"' "$value"
	return 0
}

_gh_secondary_cooldown_write_until() {
	local reason="$1"
	local response_text="${2:-}"
	local expires_at="${3:-}"
	local decision_branch="${4:-$reason}"
	local now=""
	local expires=""
	local file=""
	local dir=""
	local request_id=""
	local status=""
	local retry_after=""
	local ratelimit_limit=""
	local ratelimit_remaining=""
	local ratelimit_reset=""
	local ratelimit_used=""
	local ratelimit_resource=""
	local body_classification=""
	local caller_family=""
	local endpoint_family=""
	local reason_json=""
	local request_id_json=""
	local decision_branch_json=""
	local status_json=""
	local retry_after_json=""
	local ratelimit_limit_json=""
	local ratelimit_remaining_json=""
	local ratelimit_reset_json=""
	local ratelimit_used_json=""
	local ratelimit_resource_json=""
	local body_classification_json=""
	local caller_family_json=""
	local endpoint_family_json=""

	now="$(_gh_secondary_cooldown_now)"
	if [[ "$expires_at" =~ ^[0-9]+$ && "$expires_at" -gt "$now" ]]; then
		expires="$expires_at"
	else
		expires=$((now + AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS))
	fi
	file="$(_gh_secondary_cooldown_file)"
	dir="${file%/*}"
	request_id="$(_gh_secondary_cooldown_request_id "$response_text")"
	status="$(_gh_secondary_cooldown_status "$response_text")"
	retry_after="$(_gh_secondary_cooldown_header_value "$response_text" "retry-after")"
	ratelimit_limit="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-limit")"
	ratelimit_remaining="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-remaining")"
	ratelimit_reset="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-reset")"
	ratelimit_used="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-used")"
	ratelimit_resource="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-resource")"
	body_classification="$(_gh_secondary_cooldown_body_classification "$response_text" "$status" "$ratelimit_remaining")"
	caller_family="$(_gh_secondary_cooldown_caller_family)"
	endpoint_family="$(_gh_secondary_cooldown_endpoint_family)"
	mkdir -p "$dir" 2>/dev/null || return 1

	if command -v jq >/dev/null 2>&1; then
		jq -n \
			--arg reason "$reason" \
			--arg first_seen "$now" \
			--arg expires_at "$expires" \
			--arg request_id "$request_id" \
			--arg decision_branch "$decision_branch" \
			--arg status "$status" \
			--arg retry_after "$retry_after" \
			--arg ratelimit_limit "$ratelimit_limit" \
			--arg ratelimit_remaining "$ratelimit_remaining" \
			--arg ratelimit_reset "$ratelimit_reset" \
			--arg ratelimit_used "$ratelimit_used" \
			--arg ratelimit_resource "$ratelimit_resource" \
			--arg body_classification "$body_classification" \
			--arg caller_family "$caller_family" \
			--arg endpoint_family "$endpoint_family" \
			'{reason:$reason, first_seen:($first_seen|tonumber), expires_at:($expires_at|tonumber), last_request_id:$request_id, diagnostic:{decision_branch:$decision_branch, http_status:$status, request_id:$request_id, body_classification:$body_classification, caller_family:$caller_family, endpoint_family:$endpoint_family, headers:{retry_after:$retry_after, x_ratelimit_limit:$ratelimit_limit, x_ratelimit_remaining:$ratelimit_remaining, x_ratelimit_reset:$ratelimit_reset, x_ratelimit_used:$ratelimit_used, x_ratelimit_resource:$ratelimit_resource}}}' >"${file}.tmp" || {
			printf 'Failed to write to %s\n' "${file}.tmp" >&2
			return 1
		}
	else
		reason_json="$(_gh_secondary_cooldown_json_string "$reason")"
		request_id_json="$(_gh_secondary_cooldown_json_string "$request_id")"
		decision_branch_json="$(_gh_secondary_cooldown_json_string "$decision_branch")"
		status_json="$(_gh_secondary_cooldown_json_string "$status")"
		retry_after_json="$(_gh_secondary_cooldown_json_string "$retry_after")"
		ratelimit_limit_json="$(_gh_secondary_cooldown_json_string "$ratelimit_limit")"
		ratelimit_remaining_json="$(_gh_secondary_cooldown_json_string "$ratelimit_remaining")"
		ratelimit_reset_json="$(_gh_secondary_cooldown_json_string "$ratelimit_reset")"
		ratelimit_used_json="$(_gh_secondary_cooldown_json_string "$ratelimit_used")"
		ratelimit_resource_json="$(_gh_secondary_cooldown_json_string "$ratelimit_resource")"
		body_classification_json="$(_gh_secondary_cooldown_json_string "$body_classification")"
		caller_family_json="$(_gh_secondary_cooldown_json_string "$caller_family")"
		endpoint_family_json="$(_gh_secondary_cooldown_json_string "$endpoint_family")"
		printf '{"reason":%s,"first_seen":%s,"expires_at":%s,"last_request_id":%s,"diagnostic":{"decision_branch":%s,"http_status":%s,"request_id":%s,"body_classification":%s,"caller_family":%s,"endpoint_family":%s,"headers":{"retry_after":%s,"x_ratelimit_limit":%s,"x_ratelimit_remaining":%s,"x_ratelimit_reset":%s,"x_ratelimit_used":%s,"x_ratelimit_resource":%s}}}\n' \
			"$reason_json" "$now" "$expires" "$request_id_json" "$decision_branch_json" "$status_json" "$request_id_json" "$body_classification_json" "$caller_family_json" "$endpoint_family_json" "$retry_after_json" "$ratelimit_limit_json" "$ratelimit_remaining_json" "$ratelimit_reset_json" "$ratelimit_used_json" "$ratelimit_resource_json" >"${file}.tmp" || {
			printf 'Failed to write to %s\n' "${file}.tmp" >&2
			return 1
		}
	fi
	mv "${file}.tmp" "$file" || return 1
	printf '[gh-cooldown] secondary-rate-limit active=true expires_at=%s reason=%s\n' "$expires" "$reason" >&2
	return 0
}

_gh_secondary_cooldown_write() {
	local reason="$1"
	local response_text="${2:-}"
	_gh_secondary_cooldown_write_until "$reason" "$response_text" ""
	return $?
}

_gh_secondary_cooldown_header_value() {
	local response_text="$1"
	local header_name="$2"
	printf '%s\n' "$response_text" | awk -v name="$header_name" '
		BEGIN { target = tolower(name) ":" }
		{ line = $0; sub(/\r$/, "", line); if (line == "") { exit } lower = tolower(line); if (index(lower, target) == 1) { sub(/^[^:]*:[[:space:]]*/, "", line); print line; exit } }
	' 2>/dev/null
	return 0
}

_gh_secondary_cooldown_status() {
	local response_text="$1"
	printf '%s\n' "$response_text" | awk '
		{ line = $0; sub(/\r$/, "", line); if (line == "") { exit } }
		line ~ /^HTTP\// { split(line, parts, /[[:space:]]+/); print parts[2]; exit }
	' 2>/dev/null || printf ''
	return 0
}

_gh_secondary_cooldown_header_expires_at() {
	local response_text="$1"
	local now=""
	local retry_after=""
	local reset_at=""

	now="$(_gh_secondary_cooldown_now)"
	retry_after="$(_gh_secondary_cooldown_header_value "$response_text" "retry-after")"
	if [[ "$retry_after" =~ ^[0-9]+$ && "$retry_after" -gt 0 ]]; then
		printf '%s' $((now + retry_after))
		return 0
	fi
	reset_at="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-reset")"
	if [[ "$reset_at" =~ ^[0-9]+$ && "$reset_at" -gt "$now" ]]; then
		printf '%s' "$reset_at"
		return 0
	fi
	printf '%s' $((now + AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS))
	return 0
}

_gh_secondary_cooldown_record_response_if_needed() {
	local rc="$1"
	local response_text="${2:-}"
	local status=""
	local remaining=""
	local expires_at=""

	status="$(_gh_secondary_cooldown_status "$response_text")"
	remaining="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-remaining")"
	case "$status" in
	403|429)
		expires_at="$(_gh_secondary_cooldown_header_expires_at "$response_text")"
		_gh_secondary_cooldown_write_until "github-api-rate-limit-status-${status}" "$response_text" "$expires_at" "status-${status}" || true
		return 0
		;;
	esac
	if [[ "$remaining" =~ ^[0-9]+$ && "$remaining" -eq 0 ]]; then
		expires_at="$(_gh_secondary_cooldown_header_expires_at "$response_text")"
		_gh_secondary_cooldown_write_until "github-api-rate-limit-remaining-zero" "$response_text" "$expires_at" "remaining-zero" || true
		return 0
	fi
	if [[ "$rc" -ne 0 ]]; then
		_gh_secondary_cooldown_detect "$response_text" || return 0
		_gh_secondary_cooldown_write_until "github-secondary-rate-limit" "$response_text" "" "secondary-text" || true
	fi
	return 0
}

_gh_secondary_cooldown_expires_at() {
	local file=""
	file="$(_gh_secondary_cooldown_file)"
	[[ -f "$file" ]] || return 1
	if command -v jq >/dev/null 2>&1; then
		jq -r '.expires_at // 0' "$file" 2>/dev/null
		return 0
	fi
	sed -nE 's/.*"expires_at"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$file" | sed -n '1p'
	return 0
}

_gh_secondary_cooldown_active() {
	local expires=""
	local now=""
	expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	[[ "$expires" =~ ^[0-9]+$ ]] || return 1
	now="$(_gh_secondary_cooldown_now)"
	[[ "$expires" -gt "$now" ]] || return 1
	return 0
}

_gh_secondary_system_boot_ts() {
	local boot_ts=""
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

_gh_secondary_read_ramp_phase() {
	local now=""
	local boot_ts=""
	local expires=""
	now="$(_gh_secondary_cooldown_now)"
	boot_ts="$(_gh_secondary_system_boot_ts 2>/dev/null || true)"
	if [[ "$boot_ts" =~ ^[0-9]+$ && "$AIDEVOPS_GH_READ_RAMP_BOOT_SECS" =~ ^[0-9]+$ ]]; then
		if [[ "$now" -ge "$boot_ts" && $((now - boot_ts)) -lt "$AIDEVOPS_GH_READ_RAMP_BOOT_SECS" ]]; then
			printf 'boot'
			return 0
		fi
	fi
	expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	if [[ "$expires" =~ ^[0-9]+$ && "$AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS" =~ ^[0-9]+$ ]]; then
		if [[ "$now" -ge "$expires" && $((now - expires)) -lt "$AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS" ]]; then
			printf 'cooldown-recovery'
			return 0
		fi
	fi
	return 1
}

_gh_secondary_read_ramp_state_file() {
	printf '%s' "$AIDEVOPS_GH_READ_RAMP_STATE_FILE"
	return 0
}

_gh_secondary_read_ramp_take_token() {
	local phase="$1"
	local now=""
	local minute=""
	local file=""
	local dir=""
	local lock_dir=""
	local old_phase=""
	local old_minute=""
	local old_count=""
	local count=0
	[[ "$AIDEVOPS_GH_READ_RAMP_BUDGET" =~ ^[0-9]+$ && "$AIDEVOPS_GH_READ_RAMP_BUDGET" -gt 0 ]] || return 0
	now="$(_gh_secondary_cooldown_now)"
	minute=$((now / 60))
	file="$(_gh_secondary_read_ramp_state_file)"
	dir="${file%/*}"
	lock_dir="${file}.lock"
	mkdir -p "$dir" 2>/dev/null || return 0
	if ! mkdir "$lock_dir" 2>/dev/null; then
		return 0
	fi
	if [[ -r "$file" ]]; then
		IFS=$'\t' read -r old_phase old_minute old_count <"$file" || true
	fi
	if [[ "$old_phase" == "$phase" && "$old_minute" == "$minute" && "$old_count" =~ ^[0-9]+$ ]]; then
		count="$old_count"
	fi
	if [[ "$count" -ge "$AIDEVOPS_GH_READ_RAMP_BUDGET" ]]; then
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	fi
	count=$((count + 1))
	printf '%s\t%s\t%s\n' "$phase" "$minute" "$count" >"${file}.tmp" 2>/dev/null || {
		rmdir "$lock_dir" 2>/dev/null || true
		return 0
	}
	mv "${file}.tmp" "$file" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_gh_secondary_read_ramp_log_deferred() {
	local phase="$1"
	local budget="$AIDEVOPS_GH_READ_RAMP_BUDGET"
	if [[ "$_GH_SECONDARY_COOLDOWN_LOGGED_RAMP" -eq 1 ]]; then
		return 0
	fi
	printf '[gh-cooldown] read-ramp active=true phase=%s budget_per_minute=%s action=defer\n' "$phase" "$budget" >&2
	_GH_SECONDARY_COOLDOWN_LOGGED_RAMP=1
	return 0
}

_gh_secondary_read_ramp_preflight() {
	local op_class="${1:-}"
	local phase=""
	[[ -n "$op_class" ]] || op_class="$_GH_SECONDARY_READ_OP"
	[[ "${AIDEVOPS_GH_READ_RAMP_ENABLED:-1}" == "1" ]] || return 0
	[[ "$op_class" == "$_GH_SECONDARY_READ_OP" ]] || return 0
	[[ "${AIDEVOPS_GH_READ_RAMP_OVERRIDE:-0}" == "1" ]] && return 0
	phase="$(_gh_secondary_read_ramp_phase 2>/dev/null || true)"
	[[ -n "$phase" ]] || return 0
	_gh_secondary_read_ramp_take_token "$phase" && return 0
	_gh_secondary_read_ramp_log_deferred "$phase"
	return 75
}

_gh_secondary_cooldown_log_active_once() {
	local op_class="$1"
	local expires=""
	if [[ "$_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE" -eq 1 ]]; then
		return 0
	fi
	expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || printf 'unknown')"
	printf '[gh-cooldown] secondary-rate-limit active=true skip=%s expires_at=%s\n' "$op_class" "$expires" >&2
	_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE=1
	return 0
}

_gh_secondary_cooldown_preflight() {
	local op_class="${1:-}"
	[[ -n "$op_class" ]] || op_class="$_GH_SECONDARY_READ_OP"
	if ! _gh_secondary_cooldown_active; then
		_gh_secondary_read_ramp_preflight "$op_class" || return $?
		return 0
	fi
	if [[ "${AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE:-0}" == "1" ]]; then
		printf '[gh-cooldown] secondary-rate-limit override=true op=%s actor=%s\n' \
			"$op_class" "${GITHUB_ACTOR:-${USER:-unknown}}" >&2
		return 0
	fi
	_gh_secondary_cooldown_log_active_once "$op_class"
	return 75
}

_gh_secondary_cooldown_record_if_needed() {
	local rc="$1"
	local response_text="${2:-}"
	_gh_secondary_cooldown_record_response_if_needed "$rc" "$response_text"
	return 0
}
