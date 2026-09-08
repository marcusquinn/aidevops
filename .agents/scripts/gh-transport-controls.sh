#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Shared transport boundary for the PATH shim, including raw agent commands.

[[ -n "${_GH_TRANSPORT_CONTROLS_LOADED:-}" ]] && return 0
_GH_TRANSPORT_CONTROLS_LOADED=1
_GHGT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=./shared-gh-secondary-cooldown.sh
source "${_GHGT_DIR}/shared-gh-secondary-cooldown.sh"

_gh_transport_preflight() {
	local op_class="read"
	local arg=""
	case "${1:-}:${2:-}" in
	*:create | *:edit | *:comment | *:close | *:reopen | *:lock | *:unlock | *:merge | *:review | *:delete | *:ready | *:rerun) op_class="write" ;;
	esac
	for arg in "$@"; do
		case "$arg" in POST | PATCH | PUT | DELETE) op_class="write" ;; esac
	done
	# Wrappers may have charged the boot/recovery ramp already. Always recheck
	# the actual cooldown at dispatch; skip only a duplicate ramp reservation.
	local AIDEVOPS_GH_READ_RAMP_OVERRIDE="${AIDEVOPS_GH_READ_RAMP_OVERRIDE:-0}"
	[[ "${AIDEVOPS_GH_WRAPPER_PREFLIGHT:-0}" != 1 ]] || AIDEVOPS_GH_READ_RAMP_OVERRIDE=1
	_gh_search_cooldown_preflight "$@" || return $?
	_gh_secondary_cooldown_preflight "$op_class"
	return $?
}

_gh_transport_record_error() {
	local rc="$1"
	local error_file="$2"
	local response="${3:-}"
	[[ "$rc" -ne 0 || -n "$response" ]] || return 0
	# Native diagnostics are used only by the existing sanitizing classifier;
	# never log command argv, credentials, endpoint values or response bodies.
	response="${response}$(<"$error_file")"
	AIDEVOPS_GH_COOLDOWN_NO_PROBE=1 \
		_gh_secondary_cooldown_record_if_needed "$rc" "$response" \
		"GH-CLI" "unknown" "" "transport" "gh" "${AIDEVOPS_PULSE_STAGE:-unknown}"
	return 0
}

_gh_transport_capture_errors() {
	local error_file=""
	local rc=0
	# Preserve native terminal/editor/progress behaviour in an attached TTY.
	if [[ -t 2 ]]; then
		"$@"
		return $?
	fi
	mkdir -p "${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}" || return 75
	error_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/gh-transport-error.XXXXXX") || return 75
	"$@" 2>"$error_file" || rc=$?
	command cat "$error_file" >&2
	_gh_transport_record_error "$rc" "$error_file"
	rm -f -- "$error_file"
	return "$rc"
}

_gh_transport_local_retry_delay() {
	local metadata="$1" fallback="$2"
	python3 -c '
import json, math, sys, time
with open(sys.argv[1], encoding="utf-8") as stream:
    deadline = json.load(stream).get("retry_at")
if deadline is None:
    delay = min(5.0, float(sys.argv[2]))
elif isinstance(deadline, (int, float)) and not isinstance(deadline, bool) and math.isfinite(deadline):
    delay = max(0.0, deadline - time.time())
else:
    delay = -1
print(f"{delay:.6f}" if 0 <= delay <= 5 else "-1")
' "$metadata" "$fallback"
	return $?
}

_gh_transport_emit_local_deferral() {
	local metadata="$1"
	jq -r 'select(.attempted == false and .deferred_by == "local_admission") |
		"[gh-transport] error_kind=github-api-read-deferred attempted=false deferred_by=local_admission retry_at=\(if (.retry_at | type) == "number" then .retry_at else "unknown" end) reason=\((.reason // "unknown") | tojson)"' \
		"$metadata" >&2
	return $?
}

# _GHGT_HANDLED distinguishes unsupported-before-execution from native exit125.
# Supported REST records metadata here, not a second attempt in the ordinary
# recorder. Exact capture retains its existing multi-response-frame owner.
_gh_transport_run_rest() {
	local executable="$1" path="$2" caller="$3" retry="$4"
	shift 4
	_GHGT_HANDLED=0
	[[ "${1:-}" == api && "${AIDEVOPS_GH_TRANSPORT_GOVERNOR_DISABLE:-0}" != 1 ]] || return 125
	[[ "${AIDEVOPS_GH_EXACT_QUOTA_CAPTURE:-0}" != 1 ]] || return 125
	command -v python3 >/dev/null 2>&1 || return 125
	local temp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local metadata="" error_file="" start_ms="" end_ms="" elapsed="" rc=0
	local status="" resource="" remaining="" reset="" retry_after="" cost="" attempted="" deferred_by="" pool="" response="" outcome=success
	mkdir -p "$temp_dir" || return 75
	metadata=$(mktemp "${temp_dir}/gh-transport-meta.XXXXXX") || return 75
	error_file=$(mktemp "${temp_dir}/gh-transport-error.XXXXXX") || {
		rm -f "$metadata"
		return 75
	}
	start_ms=$(_gh_now_ms)
	python3 "${_GHGT_DIR}/gh-transport-governor.py" "$metadata" "$executable" "$@" 2>"$error_file" || rc=$?
	attempted=$(jq -r '.attempted // false' "$metadata" 2>/dev/null) || attempted=false
	deferred_by=$(jq -r '.deferred_by // ""' "$metadata" 2>/dev/null) || deferred_by=""
	if [[ "$rc" -eq 75 && "$attempted" != true && "$deferred_by" == "local_admission" ]]; then
		local retry_delay="${AIDEVOPS_GH_LOCAL_ADMISSION_RETRY_DELAY_SECONDS:-1}"
		[[ "$retry_delay" =~ ^[0-5]([.][0-9]+)?$ ]] || retry_delay=1
		retry_delay=$(_gh_transport_local_retry_delay "$metadata" "$retry_delay") || retry_delay=-1
		if [[ "$retry_delay" != -1 ]]; then
			sleep "$retry_delay"
			: >"$error_file"
			rc=0
			python3 "${_GHGT_DIR}/gh-transport-governor.py" "$metadata" "$executable" "$@" 2>"$error_file" || rc=$?
		fi
	fi
	end_ms=$(_gh_now_ms)
	command cat "$error_file" >&2
	if [[ "$rc" -eq 75 ]]; then
		_gh_transport_emit_local_deferral "$metadata" || true
	fi
	attempted=$(jq -r '.attempted // false' "$metadata" 2>/dev/null) || attempted=false
	if [[ "$rc" -eq 125 && "$attempted" != true ]]; then
		rm -f -- "$metadata" "$error_file"
		return 125
	fi
	_GHGT_HANDLED=1
	if [[ "$attempted" == true ]]; then
		# Use explicit sentinels: IFS whitespace collapses empty TSV columns.
		IFS='|' read -r status resource remaining reset retry_after cost < <(jq -r \
			'[.status,.resource,.remaining,.reset,.retry_after,.cost] | map(if . == null then "x" else tostring end) | join("|")' "$metadata")
		pool=$(_ghqa_pool_for_resource "$resource")
		[[ "$resource" != code_search ]] || pool=rest-search
		[[ "$pool" != unknown ]] || pool=rest-core
		[[ "$rc" -eq 0 ]] || outcome=error
		elapsed=$((end_ms - start_ms))
		AIDEVOPS_GH_NATIVE_EXECUTION_OUTCOME="$outcome" \
			gh_record_attempt "$path" "$caller" "$AIDEVOPS_GH_LOGICAL_ID" "" \
			"$(_shim_transport_page "$@")" "$retry" "$outcome" "$status" "$elapsed" "$cost" \
			"${AIDEVOPS_GH_AUTH_MODE:-}" "$pool" "${AIDEVOPS_GH_ROUTE_DECISION:-rest-response-owned}" "$remaining"
		[[ "$status" == x ]] || response="HTTP/1.1 ${status}"$'\n'
		[[ "$resource" == x ]] || response="${response}x-ratelimit-resource: ${resource}"$'\n'
		[[ "$remaining" == x ]] || response="${response}x-ratelimit-remaining: ${remaining}"$'\n'
		[[ "$reset" == x ]] || response="${response}x-ratelimit-reset: ${reset}"$'\n'
		[[ "$retry_after" == x ]] || response="${response}retry-after: ${retry_after}"$'\n'
	else
		gh_record_call other "$caller" "" other transport-deferred 2>/dev/null || true
	fi
	# Healthy responses do not need the multi-step error classifier. Local
	# admission stops have no server response to classify at all.
	if [[ "$attempted" == true && ("$rc" -ne 0 || "$remaining" == 0 || "$retry_after" != x || "$status" =~ ^[45]) ]]; then
		_gh_transport_record_error "$rc" "$error_file" "$response"
	fi
	rm -f -- "$metadata" "$error_file"
	return "$rc"
}

return 0
