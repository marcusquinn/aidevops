#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Capture Materialization Library
# =============================================================================
# Capture request parsing, routing, metadata, and artifact materialization helpers.
#
# Usage: source "${SCRIPT_DIR}/reach-capture-materialize-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_CAPTURE_MATERIALIZE_LIB_LOADED:-}" ]] && return 0
_REACH_CAPTURE_MATERIALIZE_LIB_LOADED=1

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

capture_extension_for_input() {
	local input_ref="$1"
	local extension="md"
	case "${input_ref##*.}" in
		html | htm) extension="html" ;;
		md | markdown) extension="md" ;;
		txt | text) extension="txt" ;;
		json) extension="json" ;;
		*) extension="md" ;;
	esac
	printf '%s' "$extension"
	return 0
}

capture_copy_file() {
	local input_ref="$1"
	local artifact_path="$2"
	if [[ ! -f "$input_ref" ]]; then
		log_error "capture file input not found"
		return 1
	fi
	cp "$input_ref" "$artifact_path"
	return 0
}

capture_fetch_url() {
	local input_ref="$1"
	local artifact_path="$2"
	if ! command_available curl; then
		log_error "curl is required for URL capture"
		return 1
	fi
	curl --fail --location --silent --show-error --max-time 30 --output "$artifact_path" "$input_ref"
	return $?
}

capture_route_json() {
	local input_ref="$1"
	local method_value="$2"
	local objective=""
	objective="capture $method_value $(capture_source_label "$input_ref" "$method_value")"
	handle_route --objective "$objective" --scope public --format json
	return $?
}

capture_route_backend() {
	local route_json="$1"
	local backend_value="$REACH_VAL_FETCH"
	if command_available python3; then
		backend_value="$(python3 - "$REACH_KEY_BACKEND" "$REACH_VAL_FETCH" "$route_json" <<'PY'
import json
import sys

backend_key, default_backend, route_json = sys.argv[1:]
try:
    route_decision = json.loads(route_json)
except Exception:
    route_decision = {}
print(route_decision.get(backend_key, default_backend))
PY
)"
	fi
	printf '%s' "$backend_value"
	return 0
}

capture_write_metadata() {
	local meta_path="$1"
	local captured_at="$2"
	local source_ref="$3"
	local source_hash="$4"
	local method_value="$5"
	local backend_value="$6"
	local route_json="$7"
	local sha256_value="$8"
	local byte_count="$9"
	local artifact_rel="${10}"
	local meta_rel="${11}"
	python3 - "$meta_path" "$captured_at" "$source_ref" "$source_hash" "$method_value" "$backend_value" "$route_json" "$sha256_value" "$byte_count" "$artifact_rel" "$meta_rel" "$REACH_KEY_SCHEMA_VERSION" "$REACH_KEY_BACKEND" "$REACH_KEY_SENSITIVITY" "$REACH_KEY_TRUST" "$REACH_VAL_UNVERIFIED" "$REACH_VAL_NONE" <<'PY'
import json
import sys

(
    meta_path,
    captured_at,
    source_ref,
    source_hash,
    method,
    backend,
    route_json,
    sha256,
    byte_count,
    artifact_rel,
    meta_rel,
    schema_key,
    backend_key,
    sensitivity_key,
    trust_key,
    unverified_value,
    none_value,
) = sys.argv[1:]
try:
    route_decision = json.loads(route_json)
except json.JSONDecodeError:
    route_decision = {schema_key: 1, backend_key: backend, "blocked_reason": "route_parse_failed"}
metadata = {
    schema_key: 1,
    "captured_at": captured_at,
    "source_ref": source_ref,
    "source_hash": source_hash,
    "method": method,
    backend_key: backend,
    "route_decision": route_decision,
    "profile_label": none_value,
    "proxy_class": none_value,
    "failure_class": none_value,
    sensitivity_key: unverified_value,
    trust_key: unverified_value,
    "sha256": sha256,
    "bytes": int(byte_count),
    "artifact_paths": [artifact_rel, meta_rel],
    "review_required": True,
}
with open(meta_path, "w", encoding="utf-8") as handle:
    json.dump(metadata, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
	return $?
}

capture_append_triage() {
	local triage_path="$1"
	local captured_at="$2"
	local sub_folder="$3"
	local source_ref="$4"
	local meta_rel="$5"
	local method_value="$6"
	local backend_value="$7"
	local source_hash="$8"
	mkdir -p "$(dirname "$triage_path")"
	python3 - "$triage_path" "$captured_at" "$sub_folder" "$source_ref" "$meta_rel" "$method_value" "$backend_value" "$source_hash" "$REACH_KEY_BACKEND" "$REACH_KEY_SENSITIVITY" "$REACH_KEY_TRUST" "$REACH_VAL_UNVERIFIED" <<'PY'
import json
import sys

triage_path, captured_at, sub_folder, source_ref, meta_rel, method, backend, source_hash, backend_key, sensitivity_key, trust_key, unverified_value = sys.argv[1:]
entry = {
    "ts": captured_at,
    "source": "reach-capture",
    "sub": sub_folder,
    "orig": source_ref,
    "path": meta_rel,
    "method": method,
    backend_key: backend,
    "provenance_hash": source_hash,
    "status": "pending",
    sensitivity_key: unverified_value,
    trust_key: unverified_value,
}
with open(triage_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n")
PY
	return $?
}

capture_parse_args() {
	REACH_CAPTURE_INPUT_REF=""
	REACH_CAPTURE_DEST="inbox"
	REACH_CAPTURE_METHOD="$REACH_VAL_AUTO"
	REACH_CAPTURE_FORMAT="json"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--input)
				shift
				REACH_CAPTURE_INPUT_REF="${1:-}"
				;;
			--dest)
				shift
				REACH_CAPTURE_DEST="${1:-}"
				;;
			--method)
				shift
				REACH_CAPTURE_METHOD="${1:-}"
				;;
			--format)
				shift
				REACH_CAPTURE_FORMAT="${1:-}"
				;;
			*)
				log_error "Unknown capture option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	return 0
}

capture_validate_request() {
	local input_ref="$1"
	local dest="$2"
	local method="$3"
	local format="$4"
	require_json_format "$format" || return 1
	if [[ -z "$input_ref" ]]; then
		log_error "capture requires --input"
		return 1
	fi
	case "$dest" in
		inbox | knowledge-inbox) ;;
		*) log_error "Invalid --dest: $dest"; return 1 ;;
	esac
	case "$method" in
		auto | file | fetch | crawl | browser) ;;
		*) log_error "Invalid --method: $method"; return 1 ;;
	esac
	if [[ "$method" == "auto" ]]; then
		if [[ -f "$input_ref" ]]; then
			method="$REACH_VAL_FILE"
		else
			method="$REACH_VAL_FETCH"
		fi
	fi
	if [[ "$method" == "$REACH_VAL_FILE" && ! -f "$input_ref" ]]; then
		log_error "capture --method file requires a local file input"
		return 1
	fi
	return 0
}

capture_resolve_method() {
	local input_ref="$1"
	local method="$2"
	if [[ "$method" == "$REACH_VAL_AUTO" ]]; then
		if [[ -f "$input_ref" ]]; then
			method="$REACH_VAL_FILE"
		else
			method="$REACH_VAL_FETCH"
		fi
	fi
	printf '%s' "$method"
	return 0
}

capture_base_dir() {
	local dest="$1"
	if [[ "$dest" == "knowledge-inbox" ]]; then
		printf '%s' '_knowledge/inbox/web'
		return 0
	fi
	printf '%s' '_inbox/web'
	return 0
}

capture_sub_folder() {
	local dest="$1"
	if [[ "$dest" == "knowledge-inbox" ]]; then
		printf '%s' 'knowledge-inbox'
		return 0
	fi
	printf '%s' 'web'
	return 0
}

capture_materialize_artifact() {
	local input_ref="$1"
	local method="$2"
	local artifact_path="$3"
	if [[ "$method" == "$REACH_VAL_FILE" ]]; then
		capture_copy_file "$input_ref" "$artifact_path" || return 1
	else
		if ! capture_fetch_url "$input_ref" "$artifact_path"; then
			rm -f "$artifact_path"
			return 1
		fi
	fi
	return 0
}

capture_token_estimate() {
	local bytes_in="$1"
	local bytes_out="$2"
	if [[ "$bytes_in" =~ ^[0-9]+$ && "$bytes_out" =~ ^[0-9]+$ ]]; then
		printf '%s' "$(((bytes_in + bytes_out + 3) / 4))"
		return 0
	fi
	printf '%s' '0'
	return 0
}

