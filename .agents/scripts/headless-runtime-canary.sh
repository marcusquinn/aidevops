#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Canary Library -- Isolated Health Probes (GH#33448)
# =============================================================================
# Sourced by headless-runtime-lib.sh before the model library. The caller supplies
# shared-constants.sh, runtime helpers and canary constants; this library does not
# change shell options when sourced or initialize runtime state.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-canary.sh"

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_CANARY_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_CANARY_LOADED=1

# Resolve sibling paths when sourced without the normal caller.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# t3549/t3558: CPU/load/saturation must never gate dispatch. Load average
# inflates under uninterruptible IO waits, and CPU spikes are often caused by
# the pulse/runners themselves. The canary now always runs (modulo the
# existing negative cache and binary-validity checks) and timeout-class
# failures stay `timeout`; RAM/disk/provider/runtime checks are responsible
# for real launch blocking.
#
# This stub is retained for one release so existing callers and tests that
# invoke `_check_system_overload` continue to compile. It always returns
# success (0 = system OK, proceed). Remove in the release after t3549 ships.
_check_system_overload() {
	return 0
}

# t3558 (GH#22634): CPU saturation is advisory-only. Timeout-class canary
# exits classify as `timeout` regardless of load/CPU state so pulse/runner
# CPU spikes cannot lengthen dispatch backoff.
_classify_canary_failure_reason() {
	local output_file="$1"
	local exit_code="$2"
	local reason
	reason=$(classify_failure_reason "$output_file")
	case "$reason" in
		access_denied | auth_error | quota_exceeded | rate_limit | provider_error)
			printf '%s' "$reason"
			return 0
			;;
	esac
	case "$exit_code" in
		124 | 137 | 142)
			printf '%s' "timeout"
			return 0
			;;
		126 | 127)
			printf '%s' "runtime_error"
			return 0
			;;
	esac
	if [[ "$reason" == "local_error" ]]; then
		local lowered=""
		lowered=$(_read_failure_output_lowercase "$output_file")
		if ! _classify_local_runtime_failure "$lowered" >/dev/null; then
			printf '%s' "inconclusive"
			return 0
		fi
	fi
	printf '%s' "local_error"
	return 0
}

_record_canary_provider_backoff() {
	local canary_model="$1"
	local canary_reason="$2"
	local canary_output="$3"
	case "$canary_reason" in
	access_denied | auth_error | quota_exceeded | rate_limit | provider_error)
		local canary_provider
		canary_provider=$(extract_provider "$canary_model" 2>/dev/null || printf '%s' "")
		if [[ -n "$canary_provider" ]]; then
			record_provider_backoff "$canary_provider" "$canary_reason" "$canary_output" "$canary_model" || true
		fi
		;;
	*) ;;
	esac
	return 0
}

_canary_pass_cache_is_fresh() {
	local cache_file="$1"
	if [[ ! -f "$cache_file" ]]; then
		return 1
	fi
	local last_pass
	last_pass=$(cat "$cache_file" 2>/dev/null || echo "0")
	local now
	now=$(date +%s)
	local age=$((now - last_pass))
	if [[ "$age" -lt "$CANARY_CACHE_TTL_SECONDS" ]]; then
		return 0
	fi
	return 1
}

_canary_negative_cache_is_active() {
	local fail_cache_file="$1"
	local fail_reason_file="$2"
	if [[ "${AIDEVOPS_SKIP_CANARY_NEG_CACHE:-0}" == "1" ]] || [[ ! -f "$fail_cache_file" ]]; then
		return 1
	fi
	local last_fail
	local neg_now
	local neg_age
	local active_ttl
	local fail_reason
	last_fail=$(cat "$fail_cache_file" 2>/dev/null || echo "0")
	neg_now=$(date +%s)
	neg_age=$((neg_now - last_fail))
	fail_reason=$(cat "$fail_reason_file" 2>/dev/null || echo "transient")
	# t2887/t3558: Structural failures retain a longer negative-cache TTL;
	# CPU/load overload is intentionally not a distinct TTL class.
	case "$fail_reason" in
	config_error) active_ttl="$CANARY_CONFIG_ERROR_TTL_SECONDS" ;;
	*) active_ttl="$CANARY_NEGATIVE_TTL_SECONDS" ;;
	esac
	if [[ "$last_fail" =~ ^[0-9]+$ ]] && [[ "$neg_age" -ge 0 ]] && [[ "$neg_age" -lt "$active_ttl" ]]; then
		print_warning "Canary negative cache active (age=${neg_age}s, ttl=${active_ttl}s, reason=${fail_reason}) — failing fast (t2814/t2887/t3210)"
		return 0
	fi
	return 1
}

_resolve_canary_opencode_binary() {
	local fail_cache_file="$1"
	local fail_reason_file="$2"
	_CANARY_EFFECTIVE_OPENCODE_BIN="${HEADLESS_OPENCODE_BIN:-$OPENCODE_BIN_DEFAULT}"
	local validate_rc=0
	_validate_opencode_binary "$_CANARY_EFFECTIVE_OPENCODE_BIN" || validate_rc=$?
	if [[ "$validate_rc" -eq 0 ]]; then
		return 0
	fi

	# GH#21003: reuse the version captured by binary validation.
	local wrong_version="${_VALIDATE_OC_VERSION:-<missing>}"
	local alt_bin=""
	if alt_bin=$(_find_alternative_opencode_binary); then
		print_warning "Canary: headless OpenCode binary='${_CANARY_EFFECTIVE_OPENCODE_BIN}' is invalid (version='${wrong_version}', rc=${validate_rc}) — falling back to '${alt_bin}' (t2887)"
		_CANARY_EFFECTIVE_OPENCODE_BIN="$alt_bin"
		export OPENCODE_BIN="$alt_bin"
		return 0
	fi

	# Structural failure: stamp config_error so later attempts fail fast.
	print_warning "Canary: headless OpenCode binary='${_CANARY_EFFECTIVE_OPENCODE_BIN}' returns '${wrong_version}' (rc=${validate_rc}) — not anomalyco/opencode."
	print_warning "Canary: searched $(_opencode_fixed_candidate_dirs_for_warning) — no valid binary found."
	local package="opencode-ai"
	_headless_opencode_profile_is_v2 && package="@opencode/cli"
	print_warning "Canary: install with 'npm install -g ${package}' or set OPENCODE_BIN to a valid binary (t2887)."
	mkdir -p "${STATE_DIR}" 2>/dev/null || true
	date +%s >"$fail_cache_file" 2>/dev/null || true
	printf 'config_error\n' >"$fail_reason_file" 2>/dev/null || true
	return 1
}

_select_canary_model() {
	local canary_model="$1"
	if [[ -z "$canary_model" ]]; then
		while IFS= read -r canary_model; do
			[[ -n "$canary_model" ]] && break
		done < <(get_configured_models)
	fi
	if [[ -z "$canary_model" ]]; then
		canary_model="$DEFAULT_HEADLESS_MODELS"
	fi
	printf '%s' "$canary_model"
	return 0
}

_prepare_canary_isolation() {
	local canary_model="$1"
	# A fresh DB avoids opening a large shared opencode.db during the probe.
	local _canary_data_dir=""
	_canary_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-canary-db.XXXXXX")
	mkdir -p "${_canary_data_dir}/opencode"
	# Isolated config avoids stale global default_agent validation. Include the
	# aidevops plugin when present so OAuth follows the worker auth path.
	local _canary_config_dir=""
	_canary_config_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-canary-config.XXXXXX")
	mkdir -p "${_canary_config_dir}/opencode"
	local _canary_plugin_path
	local _canary_plugin_entry="index.mjs"
	local _canary_plugin_key="plugin"
	if _headless_opencode_profile_is_v2; then
		_canary_plugin_entry="v2-plugin"
		_canary_plugin_key="plugins"
	fi
	_canary_plugin_path="${AIDEVOPS_PLUGIN_INDEX:-${HOME}/.aidevops/agents/plugins/opencode-aidevops/${_canary_plugin_entry}}"
	local _canary_plugin_url=""
	if [[ -e "$_canary_plugin_path" ]]; then
		_canary_plugin_url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).absolute().as_uri())' "$_canary_plugin_path" 2>/dev/null || printf 'file://%s' "$_canary_plugin_path")
	fi
	jq -n --arg plugin_url "$_canary_plugin_url" --arg plugin_key "$_canary_plugin_key" \
		'{"$schema":"https://opencode.ai/config.json"} + (if $plugin_url == "" then {} else {($plugin_key): [$plugin_url]} end)' \
		>"${_canary_config_dir}/opencode/opencode.json"

	local _canary_default_provider="anthropic"
	local _canary_provider
	_canary_provider=$(extract_provider "$canary_model" 2>/dev/null || printf '%s' "$_canary_default_provider")
	[[ -n "$_canary_provider" ]] || _canary_provider="$_canary_default_provider"
	local _oc_auth="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
	if [[ -f "$_oc_auth" ]]; then
		copy_scoped_opencode_auth "$_oc_auth" "${_canary_data_dir}/opencode/auth.json" "$_canary_provider"
	fi
	# Mirror worker OAuth rotation before invoking OpenCode (t3362).
	if [[ -f "${_canary_data_dir}/opencode/auth.json" ]] && declare -F _maybe_rotate_isolated_auth >/dev/null 2>&1; then
		XDG_DATA_HOME="$_canary_data_dir" _maybe_rotate_isolated_auth \
			"${_canary_data_dir}/opencode/auth.json" "$_canary_provider" || true
	fi

	_CANARY_DATA_DIR="$_canary_data_dir"
	_CANARY_CONFIG_DIR="$_canary_config_dir"
	return 0
}

_execute_canary_probe() {
	local _effective_opencode_bin="$1"
	local canary_model="$2"
	local canary_output="$3"
	local _canary_config_dir="$4"
	local _canary_data_dir="$5"
	local canary_attach_args=()
	local _canary_server_info=""
	if ! _headless_opencode_profile_is_v2 && _canary_server_info=$(_detect_opencode_server); then
		local _canary_url
		local _canary_pass
		_canary_url=$(echo "$_canary_server_info" | head -1)
		_canary_pass=$(echo "$_canary_server_info" | tail -1)
		canary_attach_args=(--attach "$_canary_url" --password "$_canary_pass")
	fi
	local -a canary_run_args=(run "What is two plus two? Answer with the single word: Four" \
		-m "$canary_model" --agent build)
	if _headless_opencode_profile_is_v2; then
		canary_run_args+=(--standalone)
	else
		canary_run_args+=(--dir "${HOME}")
		if [[ ${#canary_attach_args[@]} -gt 0 ]]; then
			canary_run_args+=("${canary_attach_args[@]}")
		fi
	fi

	# Prefer process-group-aware coreutils timeout; perl is the last resort.
	local _canary_timeout_cmd=()
	if command -v timeout >/dev/null 2>&1; then
		_canary_timeout_cmd=(timeout --kill-after=5s "${CANARY_TIMEOUT_SECONDS}s")
	elif command -v gtimeout >/dev/null 2>&1; then
		_canary_timeout_cmd=(gtimeout --kill-after=5s "${CANARY_TIMEOUT_SECONDS}s")
	else
		_canary_timeout_cmd=(perl -e "alarm $CANARY_TIMEOUT_SECONDS; exec @ARGV" --)
	fi

	_CANARY_PROBE_EXIT=0
	local _canary_shell_dir="$PWD"
	_headless_opencode_profile_is_v2 && _canary_shell_dir="$HOME"
	(
		cd "$_canary_shell_dir" || exit 1
		XDG_CONFIG_HOME="$_canary_config_dir" XDG_DATA_HOME="$_canary_data_dir" \
			AIDEVOPS_HEADLESS=1 \
			run_without_opencode_session_env "${_canary_timeout_cmd[@]}" \
			"$_effective_opencode_bin" "${canary_run_args[@]}"
	) >"$canary_output" 2>&1 || _CANARY_PROBE_EXIT=$?
	return 0
}

_cleanup_canary_isolation() {
	local canary_data_dir="$1"
	local canary_config_dir="$2"
	rm -rf "$canary_data_dir" 2>/dev/null || true
	rm -rf "$canary_config_dir" 2>/dev/null || true
	return 0
}

_canary_output_is_success() {
	local canary_output="$1"
	local cache_file="$2"
	local fail_cache_file="$3"
	local fail_reason_file="$4"
	if ! grep -qwi 'four' "$canary_output"; then
		return 1
	fi
	mkdir -p "${STATE_DIR}" 2>/dev/null || true
	date +%s >"$cache_file"
	rm -f "$fail_cache_file" 2>/dev/null || true
	rm -f "$fail_reason_file" 2>/dev/null || true
	rm -f "$canary_output"
	return 0
}

_record_canary_failure() {
	local canary_output="$1"
	local canary_exit="$2"
	local canary_model="$3"
	local fail_cache_file="$4"
	local fail_reason_file="$5"
	local oc_version="${_VALIDATE_OC_VERSION:-unknown}"
	print_warning "Canary test FAILED (exit=$canary_exit, model=$canary_model, opencode=$oc_version, timeout=${CANARY_TIMEOUT_SECONDS}s)"
	print_warning "Output (last 20 lines): $(tail -20 "$canary_output" 2>/dev/null || echo '<empty>')"
	local canary_reason
	canary_reason=$(_classify_canary_failure_reason "$canary_output" "$canary_exit")
	mkdir -p "${STATE_DIR}" 2>/dev/null || true
	date +%s >"$fail_cache_file" 2>/dev/null || true
	printf '%s\n' "$canary_reason" >"$fail_reason_file" 2>/dev/null || true
	_record_canary_provider_backoff "$canary_model" "$canary_reason" "$canary_output"
	rm -f "$canary_output"
	return 0
}

_run_canary_test() {
	local requested_model="${1:-}"
	local cache_file="${STATE_DIR}/canary-last-pass"
	local fail_cache_file="${STATE_DIR}/canary-last-fail"
	local fail_reason_file="${fail_cache_file}.reason"
	if _canary_pass_cache_is_fresh "$cache_file"; then
		return 0
	fi
	# t2814/t2887: fail fast while the reason-aware negative cache is active.
	if _canary_negative_cache_is_active "$fail_cache_file" "$fail_reason_file"; then
		return 1
	fi

	# t3558: no CPU/load/saturation preflight or sampling. This tests only
	# OpenCode/runtime/model health; other resource gates live elsewhere.
	if ! _resolve_canary_opencode_binary "$fail_cache_file" "$fail_reason_file"; then
		unset _CANARY_EFFECTIVE_OPENCODE_BIN
		return 1
	fi
	local _effective_opencode_bin="$_CANARY_EFFECTIVE_OPENCODE_BIN"
	unset _CANARY_EFFECTIVE_OPENCODE_BIN

	local canary_output
	canary_output=$(mktemp "${TMPDIR:-/tmp}/aidevops-canary.XXXXXX")
	local canary_model
	canary_model=$(_select_canary_model "$requested_model")
	_prepare_canary_isolation "$canary_model"
	local _canary_data_dir="$_CANARY_DATA_DIR"
	local _canary_config_dir="$_CANARY_CONFIG_DIR"
	unset _CANARY_DATA_DIR _CANARY_CONFIG_DIR

	_execute_canary_probe "$_effective_opencode_bin" "$canary_model" "$canary_output" \
		"$_canary_config_dir" "$_canary_data_dir"
	local canary_exit="${_CANARY_PROBE_EXIT:-1}"
	unset _CANARY_PROBE_EXIT
	_cleanup_canary_isolation "$_canary_data_dir" "$_canary_config_dir"
	if _canary_output_is_success "$canary_output" "$cache_file" "$fail_cache_file" "$fail_reason_file"; then
		return 0
	fi

	_record_canary_failure "$canary_output" "$canary_exit" "$canary_model" \
		"$fail_cache_file" "$fail_reason_file"
	return 1
}
