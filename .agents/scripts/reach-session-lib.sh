#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Session Library
# =============================================================================
# Profile lease and cookie-session broker command handlers.
#
# Usage: source "${SCRIPT_DIR}/reach-session-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_SESSION_LIB_LOADED:-}" ]] && return 0
_REACH_SESSION_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091  # shared constants resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# --- Functions ---

emit_profile_status_json() {
	local target_key="$1"
	local lease_file=""
	local status='missing'
	local profile_name=""
	local profile_type=""
	local auth_mode=""
	local expires_at=""
	lease_file="$(lease_file_for_target "$target_key")"
	if [[ -f "$lease_file" ]]; then
		status='expired'
		if metadata_is_unexpired "$lease_file"; then
			status='active'
		fi
		profile_name="$(json_field_value "$lease_file" 'profile_name' 2>/dev/null || true)"
		profile_type="$(json_field_value "$lease_file" 'profile_type' 2>/dev/null || true)"
		auth_mode="$(json_field_value "$lease_file" 'auth_mode' 2>/dev/null || true)"
		expires_at="$(json_field_value "$lease_file" 'expires_at' 2>/dev/null || true)"
	fi
	printf '{\042schema_version\042:1,\042target_hash\042:"%s",\042lease_status\042:"%s",\042profile_name\042:"%s",\042profile_type\042:"%s",\042auth_mode\042:"%s",\042expires_\141t\042:"%s",\042sensitivity\042:\042private\042,\042private_path_printed\042:false}\n' \
		"$(json_escape "$(safe_hash "$target_key")")" \
		"$(json_escape "$status")" \
		"$(json_escape "$profile_name")" \
		"$(json_escape "$profile_type")" \
		"$(json_escape "$auth_mode")" \
		"$(json_escape "$expires_at")"
	return 0
}

write_profile_lease_json() {
	local lease_file="$1"
	local target_key="$2"
	local profile_name="$3"
	local profile_type="$4"
	local auth_mode="$5"
	local cookie_source="$6"
	local owner="$7"
	local created_at="$8"
	local expires_at="$9"
	local sensitivity="${10}"
	local notes="${11}"
	python3 - "$lease_file" "$target_key" "$profile_name" "$profile_type" "$auth_mode" "$cookie_source" "$owner" "$created_at" "$expires_at" "$sensitivity" "$notes" <<'PY'
import json
import os
import sys

path = sys.argv[1]
data = {
    'schema_version': 1,
    'target_key': sys.argv[2],
    'profile_name': sys.argv[3],
    'profile_type': sys.argv[4],
    'auth_mode': sys.argv[5],
    'cookie_source': sys.argv[6],
    'owner': sys.argv[7],
    'created_at': sys.argv[8],
    'expires_at': sys.argv[9],
    'sensitivity': sys.argv[10],
    'notes': sys.argv[11],
}
tmp_path = path + ".tmp"
with open(tmp_path, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, sort_keys=True, indent=2)
    handle.write("\n")
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, path)
PY
	return $?
}

handle_profile_lease() {
	local target_key=""
	local profile_name=""
	local profile_type='persistent'
	local auth_mode='profile'
	local cookie_source='none'
	local owner="${USER:-unknown}"
	local ttl="30m"
	local sensitivity='private'
	local notes=""
	local force='false'
	local format='json'
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--target-key) shift; target_key="${1:-}" ;;
			--profile-name | --name) shift; profile_name="${1:-}" ;;
			--type) shift; profile_type="${1:-}" ;;
			--auth-mode) shift; auth_mode="${1:-}" ;;
			--cookie-source) shift; cookie_source="${1:-}" ;;
			--owner) shift; owner="${1:-}" ;;
			--ttl) shift; ttl="${1:-}" ;;
			--sensitivity) shift; sensitivity="${1:-}" ;;
			--notes) shift; notes="${1:-}" ;;
			--force) force="true" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown profile lease option: $arg"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ -z "$target_key" ]]; then
		log_error "profile lease requires --target-key"
		return 1
	fi
	case "$profile_type" in
		persistent | clean | warm | disposable) ;;
		*) log_error "--type must be persistent, clean, warm, or disposable"; return 1 ;;
	esac
	if [[ -z "$profile_name" ]]; then
		profile_name="reach-$(safe_key "$target_key")"
	fi
	local ttl_seconds=""
	local created_epoch=""
	local expires_epoch=""
	local created_at=""
	local expires_at=""
	local lease_file=""
	ttl_seconds="$(parse_ttl_seconds "$ttl")" || return 1
	created_epoch="$(now_epoch)"
	expires_epoch="$((created_epoch + ttl_seconds))"
	created_at="$(epoch_to_iso "$created_epoch")"
	expires_at="$(epoch_to_iso "$expires_epoch")"
	ensure_private_dir "$(reach_lease_dir)"
	lease_file="$(lease_file_for_target "$target_key")"
	if [[ -f "$lease_file" && "$force" != "true" ]] && metadata_is_unexpired "$lease_file"; then
		printf '{\042schema_version\042:1,\042target_hash\042:"%s",\042lease_status\042:\042active\042,"refused_overwrite":true,\042private_path_printed\042:false}\n' "$(json_escape "$(safe_hash "$target_key")")"
		return 2
	fi
	write_profile_lease_json "$lease_file" "$target_key" "$profile_name" "$profile_type" "$auth_mode" "$cookie_source" "$owner" "$created_at" "$expires_at" "$sensitivity" "$(sanitize_text "$notes")"
	printf '{\042schema_version\042:1,\042target_hash\042:"%s",\042lease_status\042:\042active\042,\042profile_name\042:"%s",\042profile_type\042:"%s",\042auth_mode\042:"%s",\042expires_at\042:"%s",\042sensitivity\042:"%s",\042private_path_printed\042:false}\n' \
		"$(json_escape "$(safe_hash "$target_key")")" \
		"$(json_escape "$profile_name")" \
		"$(json_escape "$profile_type")" \
		"$(json_escape "$auth_mode")" \
		"$(json_escape "$expires_at")" \
		"$(json_escape "$sensitivity")"
	return 0
}

handle_profile_release() {
	local target_key=""
	local format='json'
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--target-key) shift; target_key="${1:-}" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown profile release option: $arg"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ -z "$target_key" ]]; then
		log_error "profile release requires --target-key"
		return 1
	fi
	local released='false'
	local lease_file=""
	lease_file="$(lease_file_for_target "$target_key")"
	if [[ -f "$lease_file" ]]; then
		rm -f "$lease_file"
		released='true'
	fi
	printf '{\042schema_version\042:1,\042target_hash\042:"%s","released":%s,\042private_path_printed\042:false}\n' "$(json_escape "$(safe_hash "$target_key")")" "$(json_bool "$released")"
	return 0
}

handle_profile_status() {
	local target_key=""
	local format='json'
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--target-key) shift; target_key="${1:-}" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown profile status option: $arg"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ -z "$target_key" ]]; then
		log_error "profile status requires --target-key"
		return 1
	fi
	emit_profile_status_json "$target_key"
	return 0
}

handle_profile() {
	local subcommand="${1:-}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$subcommand" in
		lease) handle_profile_lease "$@"; return $? ;;
		release) handle_profile_release "$@"; return $? ;;
		status) handle_profile_status "$@"; return $? ;;
		*) log_error "profile requires lease, release, or status"; return 1 ;;
	esac
}

write_cookie_json() {
	local cookie_file="$1"
	local target_key="$2"
	local source_path="$3"
	local label="$4"
	local source_hash="$5"
	local created_at="$6"
	local expires_at="$7"
	python3 - "$cookie_file" "$target_key" "$source_path" "$label" "$source_hash" "$created_at" "$expires_at" <<'PY'
import json
import os
import sys

path = sys.argv[1]
data = {
    'schema_version': 1,
    'target_key': sys.argv[2],
    'cookie_source_path': sys.argv[3],
    'safe_label': sys.argv[4],
    'source_hash': sys.argv[5],
    'created_at': sys.argv[6],
    'expires_at': sys.argv[7],
    'sensitivity': 'private',
}
tmp_path = path + ".tmp"
with open(tmp_path, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, sort_keys=True, indent=2)
    handle.write("\n")
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, path)
PY
	return $?
}

handle_cookie_register() {
	local target_key=""
	local source_path=""
	local label=""
	local ttl='30m'
	local format='json'
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--target-key) shift; target_key="${1:-}" ;;
			--source | --file) shift; source_path="${1:-}" ;;
			--label) shift; label="${1:-}" ;;
			--ttl) shift; ttl="${1:-}" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown cookie register option: $arg"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ -z "$target_key" || -z "$source_path" ]]; then
		log_error "cookie register requires --target-key and --source"
		return 1
	fi
	if [[ -z "$label" ]]; then
		label="cookie-session-$(safe_hash "$source_path")"
	fi
	local ttl_seconds=""
	local created_epoch=""
	local expires_epoch=""
	local created_at=""
	local expires_at=""
	local cookie_file=""
	local source_hash=""
	ttl_seconds="$(parse_ttl_seconds "$ttl")" || return 1
	created_epoch="$(now_epoch)"
	expires_epoch="$((created_epoch + ttl_seconds))"
	created_at="$(epoch_to_iso "$created_epoch")"
	expires_at="$(epoch_to_iso "$expires_epoch")"
	ensure_private_dir "$(reach_cookie_dir)"
	cookie_file="$(cookie_file_for_target "$target_key")"
	source_hash="$(safe_hash "$source_path")"
	write_cookie_json "$cookie_file" "$target_key" "$source_path" "$(sanitize_text "$label")" "$source_hash" "$created_at" "$expires_at"
	printf '{\042schema_version\042:1,\042target_hash\042:"%s","cookie_status":\042registered\042,\042safe_label\042:"%s",\042source_hash\042:"%s",\042expires_\141t\042:"%s",\042sensitivity\042:\042private\042,\042private_path_printed\042:false}\n' \
		"$(json_escape "$(safe_hash "$target_key")")" \
		"$(json_escape "$(sanitize_text "$label")")" \
		"$(json_escape "$source_hash")" \
		"$(json_escape "$expires_at")"
	return 0
}

handle_cookie_status() {
	local target_key=""
	local format='json'
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--target-key) shift; target_key="${1:-}" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown cookie status option: $arg"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ -z "$target_key" ]]; then
		log_error "cookie status requires --target-key"
		return 1
	fi
	local cookie_file=""
	local status='missing'
	local safe_label=""
	local source_hash=""
	local expires_at=""
	cookie_file="$(cookie_file_for_target "$target_key")"
	if [[ -f "$cookie_file" ]]; then
		status='expired'
		if metadata_is_unexpired "$cookie_file"; then
			status='registered'
		fi
		safe_label="$(json_field_value "$cookie_file" 'safe_label' 2>/dev/null || true)"
		source_hash="$(json_field_value "$cookie_file" 'source_hash' 2>/dev/null || true)"
		expires_at="$(json_field_value "$cookie_file" 'expires_at' 2>/dev/null || true)"
	fi
	printf '{\042schema_version\042:1,\042target_hash\042:"%s","cookie_status":"%s",\042safe_label\042:"%s",\042source_hash\042:"%s",\042expires_at\042:"%s",\042sensitivity\042:\042private\042,\042private_path_printed\042:false}\n' \
		"$(json_escape "$(safe_hash "$target_key")")" \
		"$(json_escape "$status")" \
		"$(json_escape "$safe_label")" \
		"$(json_escape "$source_hash")" \
		"$(json_escape "$expires_at")"
	return 0
}

handle_cookie_clear() {
	local target_key=""
	local format='json'
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--target-key) shift; target_key="${1:-}" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown cookie clear option: $arg"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ -z "$target_key" ]]; then
		log_error "cookie clear requires --target-key"
		return 1
	fi
	local cleared='false'
	local cookie_file=""
	cookie_file="$(cookie_file_for_target "$target_key")"
	if [[ -f "$cookie_file" ]]; then
		rm -f "$cookie_file"
		cleared='true'
	fi
	printf '{\042schema_version\042:1,\042target_hash\042:"%s","cleared":%s,\042private_path_printed\042:false}\n' "$(json_escape "$(safe_hash "$target_key")")" "$(json_bool "$cleared")"
	return 0
}

handle_cookie() {
	local subcommand="${1:-}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$subcommand" in
		register) handle_cookie_register "$@"; return $? ;;
		status) handle_cookie_status "$@"; return $? ;;
		clear) handle_cookie_clear "$@"; return $? ;;
		*) log_error "cookie requires status, register, or clear"; return 1 ;;
	esac
}
