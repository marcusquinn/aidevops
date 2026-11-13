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
