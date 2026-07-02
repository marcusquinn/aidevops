#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Capture Performance Library
# =============================================================================
# Capture performance telemetry, execution, and command handler helpers.
#
# Usage: source "${SCRIPT_DIR}/reach-capture-performance-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_CAPTURE_PERFORMANCE_LIB_LOADED:-}" ]] && return 0
_REACH_CAPTURE_PERFORMANCE_LIB_LOADED=1

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

capture_write_performance_record() {
	local log_path="$1"
	local captured_at="$2"
	local session_ref="$3"
	local source_ref="$4"
	local target_hash="$5"
	local operation="$6"
	local backend_value="$7"
	local agency_level="$8"
	local headed_value="$9"
	local mode_value="${10}"
	local profile_policy="${11}"
	local proxy_policy="${12}"
	local offload_value="${13}"
	local latency_ms="${14}"
	local discovery_steps="${15}"
	local token_estimate="${16}"
	local bytes_in="${17}"
	local bytes_out="${18}"
	local status_value="${19}"
	local failure_value="${20}"
	local temporary_value="${21}"
	local next_action_value="${22}"

	python3 - "$log_path" "$captured_at" "$session_ref" "$source_ref" "$target_hash" "$operation" "$backend_value" "$agency_level" "$headed_value" "$mode_value" "$profile_policy" "$proxy_policy" "$offload_value" "$latency_ms" "$discovery_steps" "$token_estimate" "$bytes_in" "$bytes_out" "$status_value" "$failure_value" "$temporary_value" "$next_action_value" <<'PY'
import json
import sys

(
    log_path,
    captured_at,
    session_ref,
    target_key,
    target_hash,
    operation,
    backend,
    agency_level,
    headed,
    mode,
    profile_class,
    proxy_class,
    offload,
    latency_ms,
    discovery_steps,
    token_estimate,
    bytes_in,
    bytes_out,
    status,
    failure_class,
    temporary,
    next_best_action,
) = sys.argv[1:]

def int_value(value, default=0):
    try:
        return int(value)
    except ValueError:
        return default

record = {
    "schema_version": 1,
    "timestamp": captured_at,
    "session_ref": session_ref,
    "target_key": target_key,
    "target_hash": target_hash,
    "operation": operation,
    "backend": backend,
    "agency_level": int_value(agency_level),
    "headed": headed == "true",
    "mode": mode,
    "profile_class": profile_class,
    "proxy_class": proxy_class,
    "offload": offload,
    "latency_ms": int_value(latency_ms),
    "discovery_steps": int_value(discovery_steps, 1),
    "token_estimate": int_value(token_estimate),
    "bytes_in": int_value(bytes_in),
    "bytes_out": int_value(bytes_out),
    "status": status,
    "failure_class": failure_class,
    "temporary": temporary == "true",
    "next_best_action": next_best_action,
}
with open(log_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
	return $?
}

capture_append_performance() {
	local captured_at="$1"
	local input_ref="$2"
	local operation="$3"
	local method="$4"
	local route_json="$5"
	local latency_ms="$6"
	local bytes_in="$7"
	local bytes_out="$8"
	local status_value="$9"
	local failure_value="${10}"
	local temporary_value="${11}"
	local next_action_value="${12}"
	local log_path=""
	local source_ref=""
	local target_hash=""
	local backend_value=""
	local agency_level=""
	local headed_value=""
	local mode_value=""
	local profile_policy=""
	local proxy_policy=""
	local offload_value=""
	local token_estimate="0"
	local session_ref=""
	local discovery_steps="1"

	log_path="$(reach_performance_log_path)"
	mkdir -p "$(dirname "$log_path")"
	source_ref="$(capture_source_label "$input_ref" "$method")"
	target_hash="$(safe_sha256 "$input_ref")"
	backend_value="$(json_field_default "$route_json" "backend" "$method")"
	agency_level="$(json_field_default "$route_json" "agency_level" "0")"
	headed_value="$(json_field_default "$route_json" "headed" "false")"
	mode_value="$(json_field_default "$route_json" "mode" "$method")"
	profile_policy="$(json_field_default "$route_json" "profile_policy" "$REACH_VAL_NONE")"
	proxy_policy="$(json_field_default "$route_json" "proxy_policy" "$REACH_VAL_NONE")"
	offload_value="$(json_field_default "$route_json" "offload" "local")"
	session_ref="$(reach_session_ref)"
	token_estimate="$(capture_token_estimate "$bytes_in" "$bytes_out")"
	capture_write_performance_record "$log_path" "$captured_at" "$session_ref" "$source_ref" "$target_hash" "$operation" "$backend_value" "$agency_level" "$headed_value" "$mode_value" "$profile_policy" "$proxy_policy" "$offload_value" "$latency_ms" "$discovery_steps" "$token_estimate" "$bytes_in" "$bytes_out" "$status_value" "$failure_value" "$temporary_value" "$next_action_value"
	return $?
}

capture_execute() {
	local input_ref="$1"
	local dest="$2"
	local method="$3"
	local epoch_value=""
	local captured_at=""
	local stamp=""
	local slug=""
	local extension=""
	local base_dir=""
	local sub_folder=""
	local artifact_path=""
	local meta_path=""
	local artifact_rel=""
	local meta_rel=""
	local route_json=""
	local backend=""
	local source_ref=""
	local source_hash=""
	local sha256_value=""
	local byte_count=""
	local started_epoch=""
	local ended_epoch=""
	local latency_ms="0"
	local input_bytes="0"
	epoch_value="$(now_epoch)"
	started_epoch="$epoch_value"
	captured_at="$(epoch_to_iso "$epoch_value")"
	stamp="$(epoch_to_stamp "$epoch_value")"
	slug="$(capture_slug "$input_ref" "$method")"
	extension="$(capture_extension_for_input "$input_ref")"
	base_dir="$(capture_base_dir "$dest")"
	sub_folder="$(capture_sub_folder "$dest")"
	mkdir -p "$base_dir" "_inbox"
	artifact_path="${base_dir}/${slug}_${stamp}.${extension}"
	meta_path="${base_dir}/${slug}_${stamp}.meta.json"
	if [[ -f "$input_ref" ]]; then
		input_bytes="$(file_bytes "$input_ref")"
	else
		input_bytes="${#input_ref}"
	fi
	route_json="$(capture_route_json "$input_ref" "$method")"
	backend="$(capture_route_backend "$route_json")"
	if [[ "$method" != "$REACH_VAL_AUTO" && "$method" != "$REACH_VAL_FILE" && "$method" != "$REACH_VAL_FETCH" ]]; then
		backend="$method"
	fi
	if ! capture_materialize_artifact "$input_ref" "$method" "$artifact_path"; then
		ended_epoch="$(now_epoch)"
		latency_ms="$(((ended_epoch - started_epoch) * 1000))"
		capture_append_performance "$captured_at" "$input_ref" "capture" "$method" "$route_json" "$latency_ms" "$input_bytes" "0" "failure" "capture_failed" "true" "inspect sanitized capture failure and retry only when authorized" || true
		return 1
	fi
	artifact_rel="$(relative_path "$artifact_path")"
	meta_rel="$(relative_path "$meta_path")"
	source_ref="$(capture_source_label "$input_ref" "$method")"
	source_hash="$(safe_sha256 "$input_ref")"
	sha256_value="$(file_sha256 "$artifact_path")"
	byte_count="$(file_bytes "$artifact_path")"
	capture_write_metadata "$meta_path" "$captured_at" "$source_ref" "$source_hash" "$method" "$backend" "$route_json" "$sha256_value" "$byte_count" "$artifact_rel" "$meta_rel" || return 1
	capture_append_triage "_inbox/triage.log" "$captured_at" "$sub_folder" "$source_ref" "$meta_rel" "$method" "$backend" "$source_hash" || return 1
	ended_epoch="$(now_epoch)"
	latency_ms="$(((ended_epoch - started_epoch) * 1000))"
	capture_append_performance "$captured_at" "$input_ref" "capture" "$method" "$route_json" "$latency_ms" "$input_bytes" "$byte_count" "success" "$REACH_VAL_NONE" "false" "review staged capture metadata before promotion" || true
	printf '{"%s":1,"dest":"%s","artifact_path":"%s","meta_path":"%s","triage_log":"_inbox/triage.log","%s":"%s","%s":"%s","review_required":true}\n' \
		"$(json_escape "$REACH_KEY_SCHEMA_VERSION")" \
		"$(json_escape "$dest")" \
		"$(json_escape "$artifact_rel")" \
		"$(json_escape "$meta_rel")" \
		"$(json_escape "$REACH_KEY_SENSITIVITY")" \
		"$(json_escape "$REACH_VAL_UNVERIFIED")" \
		"$(json_escape "$REACH_KEY_TRUST")" \
		"$(json_escape "$REACH_VAL_UNVERIFIED")"
	return 0
}

handle_capture() {
	capture_parse_args "$@" || return 1
	capture_validate_request "$REACH_CAPTURE_INPUT_REF" "$REACH_CAPTURE_DEST" "$REACH_CAPTURE_METHOD" "$REACH_CAPTURE_FORMAT" || return 1
	REACH_CAPTURE_METHOD="$(capture_resolve_method "$REACH_CAPTURE_INPUT_REF" "$REACH_CAPTURE_METHOD")"
	capture_execute "$REACH_CAPTURE_INPUT_REF" "$REACH_CAPTURE_DEST" "$REACH_CAPTURE_METHOD"
	return $?
}
