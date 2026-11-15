#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Runtime utilities for dispatch-claim-helper.sh: identity, time and diagnostics.
# Sourced by the helper; configuration and sibling dependencies remain there.

[[ -n "${_DISPATCH_CLAIM_RUNTIME_LOADED:-}" ]] && return 0
_DISPATCH_CLAIM_RUNTIME_LOADED=1

#######################################
# Generate a unique nonce for this claim attempt.
# Uses /dev/urandom for uniqueness; falls back to date+PID.
# Returns: nonce string on stdout
#######################################
_generate_nonce() {
	if [[ -r /dev/urandom ]]; then
		head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
	else
		printf '%s-%s' "$(date -u '+%s%N' 2>/dev/null || date -u '+%s')" "$$"
	fi
	return 0
}

#######################################
# Get current UTC timestamp in ISO 8601 format
#######################################
_now_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

#######################################
# Get current epoch seconds
#######################################
_now_epoch() {
	date -u '+%s'
	return 0
}

# GH#37883: store " issue=<n> repo=<slug>" in the named variable so parallel
# dispatch rounds produce attributable stage lines; empty when either value is
# absent or malformed. Uses printf -v to avoid a subshell per stage line.
# Args: output variable name, issue number, repo slug
_dch_stage_context() {
	local _dsc_out="$1" _dsc_issue="${2:-}" _dsc_repo="${3:-}"
	printf -v "$_dsc_out" '%s' ""
	[[ "$_dsc_issue" =~ ^[1-9][0-9]*$ && "$_dsc_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
	printf -v "$_dsc_out" ' issue=%s repo=%s' "$_dsc_issue" "$_dsc_repo"
	return 0
}

# Emit per-call latency to runner diagnostics without exposing response bodies.
# issue_number/repo_slug are read from the calling function's scope.
_dch_timed() {
	local stage="$1" started="$SECONDS" rc=0 _dcht_context=""
	shift
	"$@" || rc=$?
	_dch_stage_context _dcht_context "${issue_number:-}" "${repo_slug:-}"
	if [[ -n "${AIDEVOPS_DISPATCH_CLAIM_CALL_LOG:-}" ]]; then
		printf '[dispatch-claim] stage=%s elapsed_s=%s rc=%s%s\n' \
			"$stage" "$((SECONDS - started))" "$rc" "$_dcht_context" >>"$AIDEVOPS_DISPATCH_CLAIM_CALL_LOG"
	else
		printf '[dispatch-claim] stage=%s elapsed_s=%s rc=%s%s\n' \
			"$stage" "$((SECONDS - started))" "$rc" "$_dcht_context" >&2
	fi
	return "$rc"
}

_dch_snapshot_valid() {
	local path="${DISPATCH_CLAIM_SNAPSHOT_FILE:-}"
	[[ -n "$path" && "$path" == "${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-claim."* && -f "$path" && ! -L "$path" && -O "$path" ]]
}

# GH#38352: the layer-6 free-verdict hint written by pulse-dispatch-dedup-layers.sh
# (_dedup_assignment_verdict_record) must be a private regular file directly in
# the private hint directory under the same temp root as the claim snapshot
# (t19022: the hints moved out of the shared root).
_dch_assignment_verdict_file_valid() {
	local path="${DISPATCH_ASSIGNMENT_VERDICT_FILE:-}"
	local dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-assignment-verdicts"
	[[ -n "$path" && "$path" == "${dir}/"* && "${path#"${dir}/"}" != */* ]] || return 1
	[[ -d "$dir" && ! -L "$dir" && -O "$dir" && -f "$path" && ! -L "$path" && -O "$path" ]] || return 1
	# The directory must also carry no group/other write bits; a find error
	# prints nothing, so this fails closed.
	[[ "$(find "$dir" -maxdepth 0 ! -perm -020 ! -perm -002 -print 2>/dev/null)" == "$dir" ]] || return 1
	return 0
}

# Record the reuse decision in the pulse call log only; standalone callers and
# captured guard output never see it.
_dch_assignment_verdict_log() {
	local result="$1" detail="$2" _dcvl_context=""
	[[ -n "${AIDEVOPS_DISPATCH_CLAIM_CALL_LOG:-}" ]] || return 0
	_dch_stage_context _dcvl_context "${issue_number:-}" "${repo_slug:-}"
	printf '[dispatch-claim] assignment_guard_reuse=%s detail=%s%s\n' \
		"$result" "$detail" "$_dcvl_context" >>"$AIDEVOPS_DISPATCH_CLAIM_CALL_LOG"
	return 0
}

#######################################
# GH#38352: decide whether the pre-claim assignment guard may reuse the layer-6
# "not assigned" verdict of this launch instead of re-running is-assigned.
# Every input must match, otherwise the full guard runs as before:
#   - the hint names this issue, repo and runner and is at most
#     DISPATCH_ASSIGNMENT_VERDICT_MAX_AGE (default 600, max 1800) seconds old;
#   - the validated claim-precheck comment snapshot has no comment created or
#     edited since 30s before layer 6 started (clock-skew margin);
#   - one fresh issue read shows the same state, assignees and labels that
#     layer 6 evaluated.
# Deleted comments can only relax a block. The post-consensus final guard and
# the claim race read the live issue regardless of this decision.
# Args: issue number, repo slug, runner login
# Returns: 0 when the verdict is reusable, 1 otherwise
#######################################
_dch_assignment_verdict_reusable() {
	local issue_number="$1" repo_slug="$2" runner="$3"
	local record="" version="" started="" v_issue="" v_repo="" v_runner="" v_meta="" now="" live_meta=""
	local max_age="${DISPATCH_ASSIGNMENT_VERDICT_MAX_AGE:-600}"
	_dch_assignment_verdict_file_valid || return 1
	[[ "$max_age" =~ ^[0-9]+$ ]] || max_age=600
	((max_age <= 1800)) || max_age=1800
	IFS= read -r record <"$DISPATCH_ASSIGNMENT_VERDICT_FILE" || record=""
	IFS=$'\t' read -r version started v_issue v_repo v_runner v_meta <<<"$record"
	if [[ "$version" != v1 || ! "$started" =~ ^[0-9]+$ || "$v_issue" != "$issue_number" ||
		"$v_repo" != "$repo_slug" || "$v_runner" != "$runner" || -z "$v_meta" ]]; then
		_dch_assignment_verdict_log miss identity
		return 1
	fi
	now=$(_now_epoch)
	if ! [[ "$now" =~ ^[0-9]+$ ]] || ((now < started || now - started > max_age)); then
		_dch_assignment_verdict_log miss age
		return 1
	fi
	if ! _dch_snapshot_valid || [[ ! -s "$DISPATCH_CLAIM_SNAPSHOT_FILE" ]] ||
		! jq -e --argjson since "$((started - 30))" --arg list array '
			[(if (type == $list and ((.[0]? | type) == $list)) then .[] else . end)[] |
				(.created_at, .updated_at)] |
			all(.[]; type == "string" and (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $since)
		' "$DISPATCH_CLAIM_SNAPSHOT_FILE" >/dev/null 2>&1; then
		_dch_assignment_verdict_log miss comments
		return 1
	fi
	live_meta=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null | jq -cSe --arg list array '
		select((.assignees | type) == $list and (.labels | type) == $list and (.state | type) == "string") |
		{state: (.state | ascii_upcase),
		assignees: ([.assignees[] | (.login? // .) | strings | ascii_downcase] | sort),
		labels: ([.labels[] | (.name? // .) | strings] | sort)}' 2>/dev/null) || live_meta=""
	if [[ -z "$live_meta" || "$live_meta" != "$v_meta" ]]; then
		_dch_assignment_verdict_log miss metadata
		return 1
	fi
	_dch_assignment_verdict_log hit layer6
	return 0
}

_resolve_device_id() {
	local device_id="${AIDEVOPS_DEVICE_ID:-}"
	if [[ -n "$device_id" && ! "$device_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]]; then
		printf 'Warning: invalid AIDEVOPS_DEVICE_ID ignored\n' >&2
		device_id=""
	fi
	if [[ -z "$device_id" && -r "$AIDEVOPS_DEVICE_ID_FILE" ]]; then
		device_id=$(tr -d '[:space:]' <"$AIDEVOPS_DEVICE_ID_FILE" 2>/dev/null || true)
		[[ "$device_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || device_id=""
	fi
	if [[ -z "$device_id" ]]; then
		device_id="device-$(_now_epoch)-$$-${RANDOM:-0}"
		mkdir -p "${AIDEVOPS_DEVICE_ID_FILE%/*}" 2>/dev/null || true
		(umask 077; printf '%s\n' "$device_id" >"$AIDEVOPS_DEVICE_ID_FILE") 2>/dev/null || true
	fi
	printf '%s' "$device_id"
	return 0
}

#######################################
# Parse ISO 8601 timestamp to epoch seconds
# Args: $1 = ISO timestamp (YYYY-MM-DDTHH:MM:SSZ)
# Returns: epoch seconds via stdout
#######################################
_iso_to_epoch() {
	local ts="$1"
	# Try GNU date first (Linux), then BSD date (macOS)
	date -u -d "$ts" '+%s' 2>/dev/null ||
		TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null ||
		printf '%s' "0"
	return 0
}

#######################################
# Resolve the current runner's GitHub login.
# Args: $1 = optional override login
# Returns: login string on stdout
#######################################
_resolve_runner() {
	local override="${1:-}"
	if [[ -n "$override" ]]; then
		printf '%s' "$override"
		return 0
	fi
	# Try gh API, fall back to whoami
	gh api user --jq '.login' 2>/dev/null || whoami
	return 0
}

#######################################
# t2401: Resolve the framework version from AIDEVOPS_VERSION_FILE.
# Returns: semver string on stdout, "unknown" when file is missing/empty.
# Always exit 0 — claim emission must never fail on a missing VERSION file.
#######################################
_resolve_version() {
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		local detected
		detected=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
		if [[ -n "$detected" && "$detected" != "$AIDEVOPS_UNKNOWN_VERSION" ]]; then
			printf '%s' "$detected"
			return 0
		fi
	fi
	if [[ -r "$AIDEVOPS_VERSION_FILE" ]]; then
		local ver
		ver=$(head -n1 "$AIDEVOPS_VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
		if [[ -n "$ver" ]]; then
			printf '%s' "$ver"
			return 0
		fi
	fi
	printf '%s' "$AIDEVOPS_UNKNOWN_VERSION"
	return 0
}
