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

usage() {
	cat <<'EOF'
Usage: reach-helper.sh <command> [options]

Commands:
  capabilities --format json
  doctor --format json
  route --objective <text> [--auth none|cookie|profile|manual] [--scope public|private] --format json
  help

The helper is advisory only. It does not contact arbitrary targets or mutate
profiles, cookies, proxies, inbox, knowledge, performance, or feedback stores.
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
	blocked_reason="manual authentication required"
	return 0
}

route_set_cookie_session() {
	backend="cookie_session"
	agency_level="4"
	mode="cookie_session"
	cookie_policy="reuse_approved_session"
	profile_policy="avoid"
	proxy_policy="authorized_only"
	expected_artifacts='"storage state or authenticated API response"'
	safety_notes='"reuse only approved cookie sessions","never print cookie values"'
	return 0
}

route_set_persistent_profile() {
	backend="persistent_profile"
	agency_level="4"
	mode="profile"
	headed="true"
	profile_policy="use_existing_approved_profile"
	cookie_policy="reuse_approved_session"
	proxy_policy="authorized_only"
	expected_artifacts='"profile-backed trace or download"'
	safety_notes='"use only approved persistent profiles","do not mutate profiles from this helper"'
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
	printf '{"schema_version":1,"backend":"%s","agency_level":%s,"mode":"%s","headed":%s,"profile_policy":"%s","cookie_policy":"%s","proxy_policy":"%s","offload":"%s","capture_destination":"%s","safety_notes":[%s],"expected_artifacts":[%s],"blocked_reason":"%s"}\n' \
		"$(json_escape "$backend")" \
		"$agency_level" \
		"$(json_escape "$mode")" \
		"$(json_bool "$headed")" \
		"$(json_escape "$profile_policy")" \
		"$(json_escape "$cookie_policy")" \
		"$(json_escape "$proxy_policy")" \
		"$(json_escape "$offload")" \
		"$(json_escape "$capture_destination")" \
		"$safety_notes" \
		"$expected_artifacts" \
		"$(json_escape "$safe_blocked_reason")"
	return 0
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
