#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# reach-helper.sh - Capability registry, doctor, and minimum-agency router.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

if ! type log_error &>/dev/null; then
	log_error() {
		printf '[ERROR] %s\n' "$*" >&2
		return 0
	}
fi

readonly REACH_KEY_SCHEMA_VERSION="schema_version"
readonly REACH_KEY_BACKEND="backend"
readonly REACH_KEY_SENSITIVITY="sensitivity"
readonly REACH_KEY_TRUST="trust"
readonly REACH_VAL_UNVERIFIED="unverified"
readonly REACH_VAL_NONE="none"
readonly REACH_VAL_FETCH="fetch"
readonly REACH_VAL_AUTO="auto"
readonly REACH_VAL_FILE="file"
readonly REACH_VAL_UNAVAILABLE="unavailable"

usage() {
	cat <<'EOF'
Usage: reach-helper.sh <command> [options]

Commands:
  capabilities --format json
  doctor --format json
  network doctor --format json
  fingerprint doctor --format json
  profile lease|release|status [options] --format json
  cookie status|register|clear [options] --format json
  classify-failure [--http-status <code>] [--has-login-wall true|false] [--has-captcha true|false] [--timeout true|false] [--selector-drift true|false] [--content-empty true|false] [--bot-block true|false] --format json
  route --objective <text> [--auth none|cookie|profile|manual] [--scope public|private] --format json
  capture --input <url-or-file> [--dest inbox|knowledge-inbox] [--method auto|file|fetch|crawl|browser] --format json
  help

The helper does not contact arbitrary targets. Profile/cookie broker commands
mutate only private reach metadata under the aidevops agent workspace and never
print cookie values, proxy credentials, private paths, or raw private targets.
EOF
	return 0
}

json_bool() {
	local value="$1"
	if [[ "$value" == "true" ]]; then
		printf 'true'
		return 0
	fi
	printf 'false'
	return 0
}

json_escape() {
	local input="$1"
	local output=""
	local char=""
	local i=0
	local length=${#input}

	while [[ $i -lt $length ]]; do
		char="${input:i:1}"
		case "$char" in
			'"') output+="\\\"" ;;
			\\) output+="\\\\" ;;
			$'\n') output+="\\n" ;;
			$'\r') output+="\\r" ;;
			$'\t') output+="\\t" ;;
			*) output+="$char" ;;
		esac
		i=$((i + 1))
	done

	printf '%s' "$output"
	return 0
}

sanitize_text() {
	local input="$1"
	local sanitized="$input"

	sanitized="${sanitized//http:\/\//redacted-url}"
	sanitized="${sanitized//https:\/\//redacted-url}"
	sanitized="${sanitized//@/ at-redacted }"
	sanitized="${sanitized//${HOME:-__NO_HOME__}/~}"
	printf '%s' "$sanitized"
	return 0
}

reach_workspace_dir() {
	printf '%s' "${AIDEVOPS_REACH_WORKSPACE:-${HOME}/.aidevops/.agent-workspace/reach}"
	return 0
}

reach_lease_dir() {
	printf '%s/leases' "$(reach_workspace_dir)"
	return 0
}

reach_cookie_dir() {
	printf '%s/cookie-sessions' "$(reach_workspace_dir)"
	return 0
}

ensure_private_dir() {
	local dir_path="$1"
	mkdir -p "$dir_path"
	chmod 700 "$dir_path" 2>/dev/null || true
	return 0
}

safe_key() {
	local input="$1"
	local sanitized=""
	sanitized="$(printf '%s' "$input" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
	sanitized="${sanitized##_}"
	sanitized="${sanitized%%_}"
	if [[ -z "$sanitized" ]]; then
		sanitized="target"
	fi
	printf '%s' "$sanitized"
	return 0
}

safe_hash() {
	local input="$1"
	local hash_value=""
	if command_available sha256sum; then
		# shell-portability: ignore next -- guarded by command_available; shasum/python3 fallbacks cover macOS.
		hash_value="$(printf '%s' "$input" | sha256sum | cut -d' ' -f1)"
	elif command_available shasum; then
		hash_value="$(printf '%s' "$input" | shasum -a 256 | cut -d' ' -f1)"
	elif command_available python3; then
		hash_value="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"$input")"
	else
		hash_value="$REACH_VAL_UNAVAILABLE"
	fi
	printf '%s' "${hash_value:0:16}"
	return 0
}

safe_sha256() {
	local input="$1"
	local hash_value=""
	if command_available sha256sum; then
		# shell-portability: ignore next -- guarded by command_available; shasum/python3 fallbacks cover macOS.
		hash_value="$(printf '%s' "$input" | sha256sum | cut -d' ' -f1)"
	elif command_available shasum; then
		hash_value="$(printf '%s' "$input" | shasum -a 256 | cut -d' ' -f1)"
	elif command_available python3; then
		hash_value="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"$input")"
	else
		hash_value="$REACH_VAL_UNAVAILABLE"
	fi
	printf '%s' "$hash_value"
	return 0
}

file_sha256() {
	local file_path="$1"
	local hash_value=""
	if command_available sha256sum; then
		# shell-portability: ignore next -- guarded by command_available; shasum/python3 fallbacks cover macOS.
		hash_value="$(sha256sum "$file_path" | cut -d' ' -f1)"
	elif command_available shasum; then
		hash_value="$(shasum -a 256 "$file_path" | cut -d' ' -f1)"
	elif command_available python3; then
		hash_value="$(python3 - "$file_path" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
)"
	else
		hash_value="$REACH_VAL_UNAVAILABLE"
	fi
	printf '%s' "$hash_value"
	return 0
}

file_bytes() {
	local file_path="$1"
	local byte_count=""
	if byte_count="$(wc -c <"$file_path")"; then
		byte_count="${byte_count//[[:space:]]/}"
		printf '%s' "$byte_count"
		return 0
	fi
	printf '0'
	return 0
}

now_epoch() {
	if command_available python3; then
		python3 -c 'import time; print(int(time.time()))'
		return 0
	fi
	date +%s
	return 0
}

epoch_to_iso() {
	local epoch_value="$1"
	if command_available python3; then
		python3 - "$epoch_value" <<'PY'
import datetime
import sys

timestamp = int(sys.argv[1])
if hasattr(datetime, "UTC"):
    dt = datetime.datetime.fromtimestamp(timestamp, datetime.UTC)
else:
    dt = datetime.datetime.utcfromtimestamp(timestamp)
print(dt.replace(microsecond=0, tzinfo=None).isoformat() + "Z")
PY
		return 0
	fi
	date -u -r "$epoch_value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$epoch_value" '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

epoch_to_stamp() {
	local epoch_value="$1"
	if command_available python3; then
		python3 - "$epoch_value" <<'PY'
import datetime
import sys

timestamp = int(sys.argv[1])
if hasattr(datetime, "UTC"):
    dt = datetime.datetime.fromtimestamp(timestamp, datetime.UTC)
else:
    dt = datetime.datetime.utcfromtimestamp(timestamp)
print(dt.strftime("%Y%m%dT%H%M%SZ"))
PY
		return 0
	fi
	date -u -r "$epoch_value" '+%Y%m%dT%H%M%SZ' 2>/dev/null || date -u -d "@$epoch_value" '+%Y%m%dT%H%M%SZ'
	return 0
}

relative_path() {
	local file_path="$1"
	local root_path="${2:-$PWD}"
	if [[ "$file_path" == "$root_path"/* ]]; then
		printf '%s' "${file_path#"$root_path"/}"
		return 0
	fi
	printf '%s' "$file_path"
	return 0
}

capture_source_label() {
	local input_ref="$1"
	local method_value="$2"
	local label=""
	if [[ "$method_value" == "$REACH_VAL_FILE" && -f "$input_ref" ]]; then
		label="local-file:$(basename "$input_ref")"
	elif [[ "$input_ref" =~ ^https?:// ]]; then
		label="url:$(safe_hash "$input_ref")"
	else
		label="input:$(safe_hash "$input_ref")"
	fi
	printf '%s' "$(sanitize_text "$label")"
	return 0
}

capture_slug() {
	local input_ref="$1"
	local method_value="$2"
	local slug_source=""
	if [[ "$method_value" == "$REACH_VAL_FILE" && -f "$input_ref" ]]; then
		slug_source="$(basename "$input_ref")"
	else
		slug_source="capture-$(safe_hash "$input_ref")"
	fi
	safe_key "$slug_source"
	return 0
}

parse_ttl_seconds() {
	local ttl_value="$1"
	local amount=""
	local unit=""
	if [[ ! "$ttl_value" =~ ^[0-9]+[smhd]?$ ]]; then
		log_error "TTL must be digits with optional s, m, h, or d suffix"
		return 1
	fi
	amount="${ttl_value%[smhd]}"
	unit="${ttl_value:${#amount}:1}"
	case "$unit" in
		"" | s) printf '%s' "$amount" ;;
		m) printf '%s' "$((amount * 60))" ;;
		h) printf '%s' "$((amount * 3600))" ;;
		d) printf '%s' "$((amount * 86400))" ;;
		*) log_error "Unsupported TTL unit: $unit"; return 1 ;;
	esac
	return 0
}

json_field_value() {
	local file_path="$1"
	local field_name="$2"
	if [[ ! -f "$file_path" ]]; then
		return 1
	fi
	if ! command_available python3; then
		return 1
	fi
	python3 - "$file_path" "$field_name" <<'PY'
import json
import sys

ENCODING = "utf-8"

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(sys.argv[2], "")
print(value)
PY
	return $?
}

iso_to_epoch() {
	local iso_value="$1"
	if [[ -z "$iso_value" ]]; then
		printf '0'
		return 0
	fi
	if ! command_available python3; then
		printf '0'
		return 0
	fi
	python3 - "$iso_value" <<'PY'
import datetime
import sys

value = sys.argv[1]
try:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    print(int(datetime.datetime.fromisoformat(value).timestamp()))
except Exception:
    print(0)
PY
	return 0
}

lease_file_for_target() {
	local target_key="$1"
	printf '%s/%s.json' "$(reach_lease_dir)" "$(safe_key "$target_key")"
	return 0
}

cookie_file_for_target() {
	local target_key="$1"
	printf '%s/%s.json' "$(reach_cookie_dir)" "$(safe_key "$target_key")"
	return 0
}

metadata_is_unexpired() {
	local file_path="$1"
	local expires_at=""
	local expires_epoch="0"
	local current_epoch="0"
	expires_at="$(json_field_value "$file_path" "expires_at" 2>/dev/null || true)"
	expires_epoch="$(iso_to_epoch "$expires_at")"
	current_epoch="$(now_epoch)"
	if [[ "$expires_epoch" -gt "$current_epoch" ]]; then
		return 0
	fi
	return 1
}

count_unexpired_metadata() {
	local dir_path="$1"
	local count="0"
	local metadata_file=""
	if [[ ! -d "$dir_path" ]]; then
		printf '0'
		return 0
	fi
	for metadata_file in "$dir_path"/*.json; do
		[[ -e "$metadata_file" ]] || continue
		if metadata_is_unexpired "$metadata_file"; then
			count=$((count + 1))
		fi
	done
	printf '%s' "$count"
	return 0
}

command_available() {
	local command_name="$1"
	if [[ "${AIDEVOPS_REACH_TEST_FORCE_MISSING:-}" == "1" ]]; then
		return 1
	fi
	if command -v "$command_name" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

helper_available() {
	local helper_name="$1"
	if [[ "${AIDEVOPS_REACH_TEST_FORCE_MISSING:-}" == "1" ]]; then
		return 1
	fi
	if [[ -x "${SCRIPT_DIR}/${helper_name}" ]]; then
		return 0
	fi
	if command -v "$helper_name" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

capability_available() {
	local capability_key="$1"
	if [[ "${AIDEVOPS_REACH_TEST_FORCE_MISSING:-}" == "1" ]]; then
		return 1
	fi
	case "$capability_key" in
		fetch)
			if command_available curl || command_available python3; then
				return 0
			fi
			;;
		crawler)
			if helper_available crawl4ai-helper.sh || helper_available watercrawl-helper.sh || helper_available site-crawler-helper.sh; then
				return 0
			fi
			;;
		browser)
			if helper_available agent-browser-helper.sh || helper_available browser-qa-helper.sh || command_available playwright; then
				return 0
			fi
			;;
		persistent_profile)
			if helper_available dev-browser-helper.sh || [[ -d "${HOME}/.aidevops/.agent-workspace/browser-profiles" ]]; then
				return 0
			fi
			;;
		cookie_session)
			if command_available sweet-cookie || helper_available anti-detect-helper.sh; then
				return 0
			fi
			;;
		anti_detect_profile | proxy_vpn)
			if helper_available anti-detect-helper.sh; then
				return 0
			fi
			;;
		inbox_capture)
			if helper_available inbox-helper.sh; then
				return 0
			fi
			;;
		knowledge_staging)
			if helper_available knowledge-helper.sh; then
				return 0
			fi
			;;
		performance_logging)
			if helper_available resource-metrics-helper.sh || helper_available report-token-use-helper.sh; then
				return 0
			fi
			;;
		feedback_mining)
			if helper_available quality-feedback-helper.sh || helper_available findings-to-tasks-helper.sh; then
				return 0
			fi
			;;
		*)
			return 1
			;;
	esac
	return 1
}

print_capability_object() {
	local key="$1"
	local name="$2"
	local agency="$3"
	local mode="$4"
	local available="false"

	if capability_available "$key"; then
		available="true"
	fi

	printf '{"key":"%s","name":"%s","agency":"%s","mode":"%s","available":%s}' \
		"$(json_escape "$key")" \
		"$(json_escape "$name")" \
		"$(json_escape "$agency")" \
		"$(json_escape "$mode")" \
		"$(json_bool "$available")"
	return 0
}

emit_capabilities_json() {
	printf '{"schema_version":1,"capabilities":['
	print_capability_object "fetch" "Fetch/static parse" "1" "static"
	printf ','
	print_capability_object "crawler" "Crawl4AI/WaterCrawl crawler" "2" "crawl"
	printf ','
	print_capability_object "browser" "Deterministic browser" "3" "deterministic_browser"
	printf ','
	print_capability_object "persistent_profile" "Persistent profile" "4" "profile"
	printf ','
	print_capability_object "cookie_session" "Cookie-session reuse" "4" "cookie_session"
	printf ','
	print_capability_object "anti_detect_profile" "Anti-detect profile" "6" "authorized_stealth"
	printf ','
	print_capability_object "proxy_vpn" "Proxy/VPN" "6" "authorized_proxy"
	printf ','
	print_capability_object "inbox_capture" "_inbox capture" "storage" "capture"
	printf ','
	print_capability_object "knowledge_staging" "_knowledge staging" "storage" "staging"
	printf ','
	print_capability_object "performance_logging" "_performance logging" "telemetry" "logging"
	printf ','
	print_capability_object "feedback_mining" "_feedback mining" "telemetry" "mining"
	printf ']}\n'
	return 0
}

require_json_format() {
	local format="$1"
	if [[ "$format" != "json" ]]; then
		log_error "Only --format json is supported"
		return 1
	fi
	return 0
}

handle_capabilities() {
	local format="json"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown capabilities option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	emit_capabilities_json
	return 0
}

handle_doctor() {
	local format="json"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown doctor option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	local capabilities_json=""
	local checks_json=""
	capabilities_json="$(emit_capabilities_json)"
	checks_json="${capabilities_json#*\"capabilities\":}"
	checks_json="${checks_json%\}}"
	printf '{"schema_version":1,"contacted_targets":false,"checks":'
	printf '%s' "$checks_json"
	printf '}\n'
	return 0
}

emit_network_doctor_json() {
	local proxy_available="false"
	local vpn_available="false"
	local proxy_status="missing_helper"
	local vpn_status="missing_helper"

	if capability_available "proxy_vpn"; then
		proxy_available="true"
		proxy_status="ready"
	fi
	if helper_available nostr-vpn-helper.sh || command_available wg || command_available tailscale; then
		vpn_available="true"
		vpn_status="ready"
	fi

	printf '{"schema_version":1,"contacted_targets":false,"doctor":"network","provider_class":"proxy_or_vpn","checks":[{"key":"proxy_vpn","available":%s,"status":"%s"},{"key":"vpn","available":%s,"status":"%s"}],"notes":["sanitized readiness only","no IP addresses, proxy credentials, session IDs, cookies, or private paths are printed"]}\n' \
		"$(json_bool "$proxy_available")" \
		"$(json_escape "$proxy_status")" \
		"$(json_bool "$vpn_available")" \
		"$(json_escape "$vpn_status")"
	return $?
}

emit_fingerprint_doctor_json() {
	local profile_available="false"
	local browser_available="false"
	local profile_status="missing_helper"
	local browser_status="missing_helper"

	if capability_available "anti_detect_profile"; then
		profile_available="true"
		profile_status="ready"
	fi
	if capability_available "browser"; then
		browser_available="true"
		browser_status="ready"
	fi

	printf '{"schema_version":1,"contacted_targets":false,"doctor":"fingerprint","profile_type":"persistent_clean_warm_or_disposable","checks":[{"key":"anti_detect_profile","available":%s,"status":"%s"},{"key":"deterministic_browser","available":%s,"status":"%s"}],"notes":["authorized automation only","no profile paths, session IDs, cookies, or private targets are printed"]}\n' \
		"$(json_bool "$profile_available")" \
		"$(json_escape "$profile_status")" \
		"$(json_bool "$browser_available")" \
		"$(json_escape "$browser_status")"
	return 0
}

handle_nested_doctor() {
	local doctor_name="$1"
	shift
	local subcommand="${1:-}"
	if [[ "$subcommand" != "doctor" ]]; then
		log_error "$doctor_name requires the doctor subcommand"
		return 1
	fi
	shift

	local format="json"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown $doctor_name doctor option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1

	case "$doctor_name" in
		network)
			emit_network_doctor_json
			return $?
			;;
		fingerprint)
			emit_fingerprint_doctor_json
			return $?
			;;
		*)
			log_error "Unknown doctor: $doctor_name"
			return 1
			;;
	esac
}

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

normalize_bool_option() {
	local value="$1"
	local option_name="$2"
	case "$value" in
		true | false)
			printf '%s' "$value"
			return 0
			;;
		*)
			log_error "$option_name must be true or false"
			return 1
			;;
	esac
}

classify_failure() {
	local http_status="$1"
	local has_login_wall="$2"
	local has_captcha="$3"
	local timeout="$4"
	local selector_drift="$5"
	local content_empty="$6"
	local bot_block="$7"

	failure_class="unknown"
	temporary="false"
	retry_after_seconds="0"
	next_action="stop and inspect sanitized evidence before retrying"
	safe_to_failover="false"
	requires_authorization="false"
	notes='"no credentials, cookies, IP addresses, session IDs, or private paths are included"'

	if [[ "$timeout" == "true" ]]; then
		failure_class="network_timeout"
		temporary="true"
		retry_after_seconds="60"
		next_action="retry once with backoff, then use an authorized alternate route"
		safe_to_failover="true"
	elif [[ "$has_login_wall" == "true" || "$http_status" == "401" ]]; then
		failure_class="auth_required"
		next_action="stop and obtain explicit authorization or an approved reusable session"
		requires_authorization="true"
	elif [[ "$has_captcha" == "true" ]]; then
		failure_class="captcha_required"
		temporary="true"
		next_action="pause for authorized CAPTCHA handling; do not bypass policy"
		safe_to_failover="true"
	elif [[ "$bot_block" == "true" || "$http_status" == "418" ]]; then
		failure_class="bot_block"
		temporary="true"
		retry_after_seconds="300"
		next_action="stop current identity and use only an authorized fresh profile or proxy"
		safe_to_failover="true"
	elif [[ "$http_status" == "403" ]]; then
		failure_class="scope_forbidden"
		next_action="stop; do not fail over without new authorization for the protected scope"
		requires_authorization="true"
	elif [[ "$http_status" == "407" || "$http_status" == "502" || "$http_status" == "503" ]]; then
		failure_class="proxy_unhealthy"
		temporary="true"
		retry_after_seconds="120"
		next_action="run network doctor and switch only to a healthy authorized proxy or VPN"
		safe_to_failover="true"
	elif [[ "$http_status" == "429" ]]; then
		failure_class="rate_limited"
		temporary="true"
		retry_after_seconds="300"
		next_action="respect rate limits, back off, then retry or fail over within authorization"
		safe_to_failover="true"
	elif [[ "$selector_drift" == "true" ]]; then
		failure_class="selector_drift"
		next_action="update selectors or extraction logic before retrying"
	elif [[ "$content_empty" == "true" ]]; then
		failure_class="content_empty"
		temporary="true"
		retry_after_seconds="30"
		next_action="retry with a lower-agency parser, then escalate to deterministic browser if authorized"
		safe_to_failover="true"
	elif [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
		failure_class="success"
		next_action="continue with extraction"
	elif [[ "$http_status" == "408" || "$http_status" == "504" ]]; then
		failure_class="network_timeout"
		temporary="true"
		retry_after_seconds="60"
		next_action="retry once with backoff, then use an authorized alternate route"
		safe_to_failover="true"
	fi
	return 0
}

handle_classify_failure() {
	local http_status="0"
	local has_login_wall="false"
	local has_captcha="false"
	local timeout="false"
	local selector_drift="false"
	local content_empty="false"
	local bot_block="false"
	local format="json"

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--http-status)
				shift
				http_status="${1:-0}"
				;;
			--has-login-wall)
				shift
				has_login_wall="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--has-captcha)
				shift
				has_captcha="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--timeout)
				shift
				timeout="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--selector-drift)
				shift
				selector_drift="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--content-empty)
				shift
				content_empty="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--bot-block)
				shift
				bot_block="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown classify-failure option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ ! "$http_status" =~ ^[0-9][0-9][0-9]$ && "$http_status" != "0" ]]; then
		log_error "--http-status must be a three-digit status code"
		return 1
	fi

	local failure_class=""
	local temporary=""
	local retry_after_seconds=""
	local next_action=""
	local safe_to_failover=""
	local requires_authorization=""
	local notes=""
	classify_failure "$http_status" "$has_login_wall" "$has_captcha" "$timeout" "$selector_drift" "$content_empty" "$bot_block"

	printf '{"schema_version":1,"failure_class":"%s","temporary":%s,"retry_after_seconds":%s,"next_action":"%s","safe_to_failover":%s,"requires_authorization":%s,"notes":[%s]}\n' \
		"$(json_escape "$failure_class")" \
		"$(json_bool "$temporary")" \
		"$retry_after_seconds" \
		"$(json_escape "$next_action")" \
		"$(json_bool "$safe_to_failover")" \
		"$(json_bool "$requires_authorization")" \
		"$notes"
	return 0
}

lower_text() {
	local input="$1"
	printf '%s' "$input" | tr '[:upper:]' '[:lower:]'
	return 0
}

route_set_defaults() {
	backend="fetch"
	agency_level="1"
	mode="static"
	headed="false"
	profile_policy="none"
	cookie_policy="none"
	proxy_policy="none"
	offload="local"
	capture_destination="caller_selected"
	safety_notes='"start with public/static retrieval before browser automation","route output is sanitized and advisory only"'
	expected_artifacts='"static response or parsed text"'
	failure_policy="retry_temporary_failures_only; stop on auth_required or scope_forbidden without new authorization"
	failover_order='"fetch","crawler","browser","persistent_profile","cookie_session","anti_detect_profile","proxy_vpn"'
	blocked_reason=""
	return 0
}

route_set_private_block() {
	backend="manual_review"
	agency_level="0"
	mode="manual"
	headed="false"
	profile_policy="blocked"
	cookie_policy="blocked"
	proxy_policy="blocked"
	offload="manual"
	capture_destination="caller_selected"
	safety_notes='"private scope requires explicit authorization or approved reusable session","no target details are echoed"'
	expected_artifacts='"authorization decision"'
	failure_policy="authorization_required; failover is blocked until scope is approved"
	failover_order=''
	blocked_reason="private scope requires auth cookie, profile, or manual approval"
	return 0
}

route_set_manual_auth() {
	backend="manual_review"
	agency_level="0"
	mode="manual"
	headed="true"
	profile_policy="required"
	cookie_policy="blocked"
	proxy_policy="authorized_only"
	offload="manual"
	safety_notes='"manual authentication must stay user-controlled","no credential or target details are echoed"'
	expected_artifacts='"manual auth handoff notes"'
	failure_policy="manual_authentication_required; failover is blocked until authorization is captured"
	failover_order=''
	blocked_reason="manual authentication required"
	return 0
}

route_set_cookie_session() {
	local active_cookie_sessions="0"
	active_cookie_sessions="$(count_unexpired_metadata "$(reach_cookie_dir)")"
	backend="cookie_session"
	agency_level="4"
	mode="cookie_session"
	if [[ "$active_cookie_sessions" -gt 0 ]]; then
		cookie_policy="reuse_approved_session"
	else
		cookie_policy='required'
	fi
	profile_policy="avoid"
	proxy_policy="authorized_only"
	expected_artifacts='"storage state or authenticated API response"'
	safety_notes='"reuse only approved cookie sessions","never print cookie values","cookie broker state controls session availability"'
	failure_policy="stop on auth_required or scope_forbidden; otherwise retry once before authorized failover"
	failover_order='"cookie_session","persistent_profile","browser"'
	return 0
}

route_set_persistent_profile() {
	local active_profile_leases="0"
	active_profile_leases="$(count_unexpired_metadata "$(reach_lease_dir)")"
	backend="persistent_profile"
	agency_level="4"
	mode="profile"
	headed="true"
	if [[ "$active_profile_leases" -gt 0 ]]; then
		profile_policy="use_existing_approved_profile"
	else
		profile_policy='required'
	fi
	cookie_policy="reuse_approved_session"
	proxy_policy="authorized_only"
	expected_artifacts='"profile-backed trace or download"'
	safety_notes='"use only approved persistent profiles","profile broker lease controls reuse","do not print profile paths"'
	failure_policy="stop on auth_required or scope_forbidden; do not switch identity without approval"
	failover_order='"persistent_profile","cookie_session","browser"'
	return 0
}

route_set_stealth() {
	backend="anti_detect_profile"
	agency_level="6"
	mode="authorized_stealth"
	headed="true"
	profile_policy="required"
	cookie_policy="avoid"
	proxy_policy="authorized_only"
	expected_artifacts='"authorized isolated browser trace"'
	safety_notes='"anti-detect and proxy use require explicit authorization","do not print proxy credentials"'
	failure_policy="fail over only for temporary network, rate-limit, CAPTCHA, bot-block, or empty-content classes; stop on auth_required and scope_forbidden"
	failover_order='"anti_detect_profile","proxy_vpn","browser","crawler","fetch"'
	return 0
}

route_set_browser() {
	backend="browser"
	agency_level="3"
	mode="deterministic_browser"
	headed="false"
	profile_policy="avoid"
	cookie_policy="avoid"
	proxy_policy="none"
	expected_artifacts='"DOM text, trace, screenshot only when needed, or download"'
	safety_notes='"prefer ARIA and DOM extraction over screenshots","use deterministic selectors before high-agency tools"'
	failure_policy="retry selector or temporary network failures; stop on auth_required or scope_forbidden"
	failover_order='"browser","crawler","fetch","persistent_profile"'
	return 0
}

route_set_crawler() {
	backend="crawler"
	agency_level="2"
	mode="crawl"
	profile_policy="none"
	cookie_policy="none"
	proxy_policy="none"
	expected_artifacts='"crawl manifest and extracted records"'
	safety_notes='"crawl only public or authorized content","respect robots and rate limits"'
	failure_policy="retry temporary failures with backoff; escalate to browser only when authorized"
	failover_order='"crawler","fetch","browser"'
	return 0
}

route_apply_capture_destination() {
	local objective_text="$1"
	if [[ "$objective_text" == *inbox* || "$objective_text" == *capture* ]]; then
		capture_destination="_inbox"
	elif [[ "$objective_text" == *knowledge* || "$objective_text" == *research* ]]; then
		capture_destination="_knowledge"
	elif [[ "$objective_text" == *performance* || "$objective_text" == *metric* ]]; then
		capture_destination="_performance"
	elif [[ "$objective_text" == *feedback* || "$objective_text" == *review* ]]; then
		capture_destination="_feedback"
	fi
	return 0
}

route_apply_objective() {
	local objective_text="$1"
	if [[ "$objective_text" == *proxy* || "$objective_text" == *vpn* || "$objective_text" == *geo* || "$objective_text" == *anti-detect* || "$objective_text" == *stealth* ]]; then
		route_set_stealth
	elif [[ "$objective_text" == *form* || "$objective_text" == *login* || "$objective_text" == *download* || "$objective_text" == *click* || "$objective_text" == *dashboard* || "$objective_text" == *browser* ]]; then
		route_set_browser
	elif [[ "$objective_text" == *crawl* || "$objective_text" == *sitemap* || "$objective_text" == *"many pages"* || "$objective_text" == *docs* || "$objective_text" == *documentation* ]]; then
		route_set_crawler
	fi
	return 0
}

handle_route() {
	local objective=""
	local auth="none"
	local scope="public"
	local format="json"

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--objective)
				shift
				objective="${1:-}"
				;;
			--auth)
				shift
				auth="${1:-}"
				;;
			--scope)
				shift
				scope="${1:-}"
				;;
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown route option: $arg"
				return 1
				;;
		esac
		shift || true
	done

	require_json_format "$format" || return 1
	if [[ -z "$objective" ]]; then
		log_error "route requires --objective"
		return 1
	fi
	case "$auth" in
		none | cookie | profile | manual) ;;
		*) log_error "Invalid --auth: $auth"; return 1 ;;
	esac
	case "$scope" in
		public | private) ;;
		*) log_error "Invalid --scope: $scope"; return 1 ;;
	esac

	local objective_lower
	objective_lower="$(lower_text "$objective")"
	local backend=""
	local agency_level=""
	local mode=""
	local headed=""
	local profile_policy=""
	local cookie_policy=""
	local proxy_policy=""
	local offload=""
	local capture_destination=""
	local safety_notes=""
	local expected_artifacts=""
	local failure_policy=""
	local failover_order=""
	local blocked_reason=""
	route_set_defaults

	if [[ "$scope" == "private" && "$auth" == "none" ]]; then
		route_set_private_block
	elif [[ "$auth" == "manual" ]]; then
		route_set_manual_auth
	elif [[ "$auth" == "cookie" ]]; then
		route_set_cookie_session
	elif [[ "$auth" == "profile" ]]; then
		route_set_persistent_profile
	else
		route_apply_objective "$objective_lower"
	fi
	route_apply_capture_destination "$objective_lower"

	local safe_blocked_reason
	safe_blocked_reason="$(sanitize_text "$blocked_reason")"
	printf '{"schema_version":1,"backend":"%s","agency_level":%s,"mode":"%s","headed":%s,"profile_policy":"%s","cookie_policy":"%s","proxy_policy":"%s","offload":"%s","capture_destination":"%s","failure_policy":"%s","failover_order":[%s],"safety_notes":[%s],"expected_artifacts":[%s],"blocked_reason":"%s"}\n' \
		"$(json_escape "$backend")" \
		"$agency_level" \
		"$(json_escape "$mode")" \
		"$(json_bool "$headed")" \
		"$(json_escape "$profile_policy")" \
		"$(json_escape "$cookie_policy")" \
		"$(json_escape "$proxy_policy")" \
		"$(json_escape "$offload")" \
		"$(json_escape "$capture_destination")" \
		"$(json_escape "$failure_policy")" \
		"$failover_order" \
		"$safety_notes" \
		"$expected_artifacts" \
		"$(json_escape "$safe_blocked_reason")"
	return 0
}

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
	epoch_value="$(now_epoch)"
	captured_at="$(epoch_to_iso "$epoch_value")"
	stamp="$(epoch_to_stamp "$epoch_value")"
	slug="$(capture_slug "$input_ref" "$method")"
	extension="$(capture_extension_for_input "$input_ref")"
	base_dir="$(capture_base_dir "$dest")"
	sub_folder="$(capture_sub_folder "$dest")"
	mkdir -p "$base_dir" "_inbox"
	artifact_path="${base_dir}/${slug}_${stamp}.${extension}"
	meta_path="${base_dir}/${slug}_${stamp}.meta.json"
	capture_materialize_artifact "$input_ref" "$method" "$artifact_path" || return 1
	artifact_rel="$(relative_path "$artifact_path")"
	meta_rel="$(relative_path "$meta_path")"
	route_json="$(capture_route_json "$input_ref" "$method")"
	backend="$(capture_route_backend "$route_json")"
	if [[ "$method" != "$REACH_VAL_AUTO" && "$method" != "$REACH_VAL_FILE" && "$method" != "$REACH_VAL_FETCH" ]]; then
		backend="$method"
	fi
	source_ref="$(capture_source_label "$input_ref" "$method")"
	source_hash="$(safe_sha256 "$input_ref")"
	sha256_value="$(file_sha256 "$artifact_path")"
	byte_count="$(file_bytes "$artifact_path")"
	capture_write_metadata "$meta_path" "$captured_at" "$source_ref" "$source_hash" "$method" "$backend" "$route_json" "$sha256_value" "$byte_count" "$artifact_rel" "$meta_rel" || return 1
	capture_append_triage "_inbox/triage.log" "$captured_at" "$sub_folder" "$source_ref" "$meta_rel" "$method" "$backend" "$source_hash" || return 1
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

main() {
	local command="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi

	case "$command" in
		help | -h | --help)
			usage
			return 0
			;;
		capabilities)
			handle_capabilities "$@"
			return $?
			;;
		doctor)
			handle_doctor "$@"
			return $?
			;;
		network)
			handle_nested_doctor "network" "$@"
			return $?
			;;
		fingerprint)
			handle_nested_doctor "fingerprint" "$@"
			return $?
			;;
		profile)
			handle_profile "$@"
			return $?
			;;
		cookie)
			handle_cookie "$@"
			return $?
			;;
		classify-failure)
			handle_classify_failure "$@"
			return $?
			;;
		capture)
			handle_capture "$@"
			return $?
			;;
		route)
			handle_route "$@"
			return $?
			;;
		*)
			log_error "Unknown command: $command"
			usage >&2
			return 1
			;;
	esac
}

main "$@"
