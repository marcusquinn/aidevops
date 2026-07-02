#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Route Library
# =============================================================================
# Minimum-agency route decision helpers and command handler.
#
# Usage: source "${SCRIPT_DIR}/reach-route-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_ROUTE_LIB_LOADED:-}" ]] && return 0
_REACH_ROUTE_LIB_LOADED=1

readonly REACH_ROUTE_VAL_ANTI_DETECT_PROFILE="anti_detect_profile"
readonly REACH_ROUTE_VAL_AUTHORIZED_ONLY="authorized_only"
readonly REACH_ROUTE_VAL_AVOID="avoid"

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
	offload_reason="short public/static fetch stays local"
	routine_candidate="false"
	compute_notes='"keep short public fetches local","offload long crawls and repeat captures only when sanitized","do not offload sensitive profile or cookie work without a private workspace and credential refs"'
	capture_destination="caller_selected"
	max_iterations="3"
	max_tool_calls="12"
	max_token_estimate="6000"
	stop_after_repeated_success="2"
	stop_on_permanent_failure="true"
	route_decision_ttl_seconds="86400"
	efficiency_policy='"prefer API or fetch before browser","prefer text and DOM extraction over screenshots","reuse approved profile leases before creating new browser state","reuse prior route decisions within TTL when objective, auth, and scope match"'
	todo_id=""
	issue_ref=""
	pr_ref=""
	capture_ref=""
	performance_ref=""
	feedback_ref=""
	safety_notes='"start with public/static retrieval before browser automation","route output is sanitized and advisory only"'
	expected_artifacts='"static response or parsed text"'
	failure_policy="retry_temporary_failures_only; stop on auth_required or scope_forbidden without new authorization"
	failover_order='"fetch","crawler","browser","persistent_profile","cookie_session","'"$REACH_ROUTE_VAL_ANTI_DETECT_PROFILE"'","proxy_vpn"'
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
	offload_reason="private unauthenticated scope requires manual authorization before compute selection"
	routine_candidate="false"
	capture_destination="caller_selected"
	max_iterations="1"
	max_tool_calls="4"
	max_token_estimate="2000"
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
	proxy_policy="$REACH_ROUTE_VAL_AUTHORIZED_ONLY"
	offload="manual"
	offload_reason="manual login, consent, CAPTCHA, payment, posting, or destructive actions stay headed and user-gated"
	routine_candidate="false"
	max_iterations="1"
	max_tool_calls="4"
	max_token_estimate="2000"
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
	profile_policy="$REACH_ROUTE_VAL_AVOID"
	proxy_policy="$REACH_ROUTE_VAL_AUTHORIZED_ONLY"
	offload="local"
	offload_reason="cookie-backed sensitive work remains local unless a private workspace and credential refs are explicitly available"
	routine_candidate="false"
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
	proxy_policy="$REACH_ROUTE_VAL_AUTHORIZED_ONLY"
	offload="local"
	offload_reason="profile-backed sensitive work remains local to preserve private browser state"
	routine_candidate="false"
	expected_artifacts='"profile-backed trace or download"'
	safety_notes='"use only approved persistent profiles","profile broker lease controls reuse","do not print profile paths"'
	failure_policy="stop on auth_required or scope_forbidden; do not switch identity without approval"
	failover_order='"persistent_profile","cookie_session","browser"'
	return 0
}

route_set_stealth() {
	backend="$REACH_ROUTE_VAL_ANTI_DETECT_PROFILE"
	agency_level="6"
	mode="authorized_stealth"
	headed="true"
	profile_policy="required"
	cookie_policy="$REACH_ROUTE_VAL_AVOID"
	proxy_policy="$REACH_ROUTE_VAL_AUTHORIZED_ONLY"
	offload="local"
	offload_reason="authorized stealth/proxy work stays local unless private isolated compute is provisioned"
	routine_candidate="false"
	expected_artifacts='"authorized isolated browser trace"'
	safety_notes='"anti-detect and proxy use require explicit authorization","do not print proxy credentials"'
	failure_policy="fail over only for temporary network, rate-limit, CAPTCHA, bot-block, or empty-content classes; stop on auth_required and scope_forbidden"
	failover_order='"'"$REACH_ROUTE_VAL_ANTI_DETECT_PROFILE"'","proxy_vpn","browser","crawler","fetch"'
	return 0
}

route_set_browser() {
	backend="browser"
	agency_level="3"
	mode="deterministic_browser"
	headed="false"
	profile_policy="$REACH_ROUTE_VAL_AVOID"
	cookie_policy="$REACH_ROUTE_VAL_AVOID"
	proxy_policy="none"
	offload="local"
	offload_reason="deterministic browser flows stay local until they are stable and sanitized"
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
	offload="worker"
	offload_reason="crawler work can be offloaded when public, rate-limited, and sanitized"
	routine_candidate="true"
	max_iterations="5"
	max_tool_calls="20"
	max_token_estimate="9000"
	expected_artifacts='"crawl manifest and extracted records"'
	safety_notes='"crawl only public or authorized content","respect robots and rate limits"'
	failure_policy="retry temporary failures with backoff; escalate to browser only when authorized"
	failover_order='"crawler","fetch","browser"'
	return 0
}

route_apply_efficiency_policy() {
	local objective_text="$1"
	local sensitive="false"

	if [[ "$objective_text" == *login* || "$objective_text" == *mfa* || "$objective_text" == *captcha* || "$objective_text" == *payment* || "$objective_text" == *post* || "$objective_text" == *submit* || "$objective_text" == *delete* || "$objective_text" == *destructive* || "$objective_text" == *consent* ]]; then
		route_set_manual_auth
		return 0
	fi

	if [[ "$objective_text" == *cookie* || "$objective_text" == *profile* || "$objective_text" == *credential* || "$objective_text" == *private* || "$objective_text" == *sensitive* ]]; then
		sensitive="true"
	fi

	if [[ "$objective_text" == *repeat* || "$objective_text" == *recurring* || "$objective_text" == *routine* || "$objective_text" == *watch* || "$objective_text" == *stable* ]]; then
		routine_candidate="true"
		stop_after_repeated_success="2"
	fi

	if [[ "$objective_text" == *long* || "$objective_text" == *crawl* || "$objective_text" == *sitemap* || "$objective_text" == *"many pages"* ]]; then
		max_iterations="5"
		max_tool_calls="20"
		max_token_estimate="9000"
	fi

	if [[ "$sensitive" == "true" ]]; then
		offload="local"
		offload_reason="sensitive profile, cookie, credential, or private-scope work is not offloaded without private workspace and credential refs"
		compute_notes='"keep sensitive state in the local/private workspace","do not offload cookies, profiles, or private targets without credential refs","sanitize audit refs before TODO, issue, or PR output"'
	elif [[ "$routine_candidate" == "true" && ( "$backend" == "crawler" || "$objective_text" == *long* || "$objective_text" == *recurring* || "$objective_text" == *routine* ) ]]; then
		offload="worker"
		offload_reason="long or recurring public capture is safe to run as a headless worker/routine when sanitized"
	else
		offload_reason="short public work stays local; revisit offload after repeated success or long crawl evidence"
	fi
	return 0
}

route_decision_id_for() {
	local objective_text="$1"
	local auth_value="$2"
	local scope_value="$3"
	local backend_value="$4"
	printf 'reach-route-%s' "$(safe_hash "${objective_text}|${auth_value}|${scope_value}|${backend_value}")"
	return 0
}

route_emit_decision_json() {
	printf '{"schema_version":1,"route_decision_id":"%s","backend":"%s","agency_level":%s,"mode":"%s","headed":%s,"profile_policy":"%s","cookie_policy":"%s","proxy_policy":"%s","budgets":{"max_iterations":%s,"max_tool_calls":%s,"max_token_estimate":%s,"stop_after_repeated_success":%s,"stop_on_permanent_failure":%s,"route_decision_ttl_seconds":%s},"efficiency_policy":[%s],"offload":"%s","offload_reason":"%s","routine_candidate":%s,"compute_notes":[%s],"capture_destination":"%s","audit_refs":{"todo_id":"%s","issue_ref":"%s","pr_ref":"%s","capture_ref":"%s","performance_ref":"%s","feedback_ref":"%s","route_decision_id":"%s"},"failure_policy":"%s","failover_order":[%s],"safety_notes":[%s],"expected_artifacts":[%s],"blocked_reason":"%s"}\n' \
		"$(json_escape "$route_decision_id")" \
		"$(json_escape "$backend")" \
		"$agency_level" \
		"$(json_escape "$mode")" \
		"$(json_bool "$headed")" \
		"$(json_escape "$profile_policy")" \
		"$(json_escape "$cookie_policy")" \
		"$(json_escape "$proxy_policy")" \
		"$max_iterations" \
		"$max_tool_calls" \
		"$max_token_estimate" \
		"$stop_after_repeated_success" \
		"$(json_bool "$stop_on_permanent_failure")" \
		"$route_decision_ttl_seconds" \
		"$efficiency_policy" \
		"$(json_escape "$offload")" \
		"$(json_escape "$offload_reason")" \
		"$(json_bool "$routine_candidate")" \
		"$compute_notes" \
		"$(json_escape "$capture_destination")" \
		"$(json_escape "$todo_id")" \
		"$(json_escape "$issue_ref")" \
		"$(json_escape "$pr_ref")" \
		"$(json_escape "$capture_ref")" \
		"$(json_escape "$performance_ref")" \
		"$(json_escape "$feedback_ref")" \
		"$(json_escape "$route_decision_id")" \
		"$(json_escape "$failure_policy")" \
		"$failover_order" \
		"$safety_notes" \
		"$expected_artifacts" \
		"$(json_escape "$safe_blocked_reason")"
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
	local backend="" agency_level="" mode="" headed=""
	local profile_policy="" cookie_policy="" proxy_policy=""
	local offload="" offload_reason="" routine_candidate="" compute_notes=""
	local capture_destination="" max_iterations="" max_tool_calls="" max_token_estimate=""
	local stop_after_repeated_success="" stop_on_permanent_failure="" route_decision_ttl_seconds=""
	local efficiency_policy="" todo_id="" issue_ref="" pr_ref="" capture_ref="" performance_ref="" feedback_ref=""
	local safety_notes="" expected_artifacts="" failure_policy="" failover_order="" blocked_reason=""
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
	route_apply_efficiency_policy "$objective_lower"
	route_apply_capture_destination "$objective_lower"

	local safe_blocked_reason
	safe_blocked_reason="$(sanitize_text "$blocked_reason")"
	local route_decision_id=""
	route_decision_id="$(route_decision_id_for "$objective_lower" "$auth" "$scope" "$backend")"
	route_emit_decision_json
	return 0
}

handle_watch() {
	local once="false"
	local dry_run="true"
	local format="json"

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--once)
				once="true"
				;;
			--dry-run)
				dry_run="true"
				;;
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown watch option: $arg"
				return 1
				;;
		esac
		shift || true
	done

	require_json_format "$format" || return 1
	printf '{"schema_version":1,"command":"watch","once":%s,"dry_run":%s,"report_only":true,"mutates":false,"default_action":"report","recommended_routine":"reach-routine.sh","notes":["dry-run/report-only by default","use route decisions before scheduling recurring capture","no issues, comments, profiles, cookies, or captures are mutated"]}\n' \
		"$(json_bool "$once")" \
		"$(json_bool "$dry_run")"
	return 0
}
