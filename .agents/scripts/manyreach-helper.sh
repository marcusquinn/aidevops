#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# manyreach-helper.sh - ManyReach API v2 integration for cold outreach automation
# Manages campaigns, leads, and sequences via the ManyReach REST API.
#
# Usage:
#   manyreach-helper.sh campaigns list
#   manyreach-helper.sh campaigns get <campaign_id>
#   manyreach-helper.sh campaigns create --name <name> [--from-email <email>]
#   manyreach-helper.sh campaigns pause <campaign_id>
#   manyreach-helper.sh campaigns resume <campaign_id>
#   manyreach-helper.sh campaigns delete <campaign_id>
#   manyreach-helper.sh leads list [--campaign <id>] [--page <n>]
#   manyreach-helper.sh leads get <lead_id>
#   manyreach-helper.sh leads add --campaign <id> --email <email> [--first-name <n>] [--last-name <n>] [--company <c>]
#   manyreach-helper.sh leads import --campaign <id> --file <csv_file>
#   manyreach-helper.sh leads unsubscribe <lead_id>
#   manyreach-helper.sh sequences list --campaign <id>
#   manyreach-helper.sh sequences get <sequence_id>
#   manyreach-helper.sh sequences add-step --sequence <id> --subject <s> --body <b> [--delay-days <n>]
#   manyreach-helper.sh mailboxes list
#   manyreach-helper.sh mailboxes get <mailbox_id>
#   manyreach-helper.sh stats campaign <campaign_id>
#   manyreach-helper.sh status
#   manyreach-helper.sh help
#
# Environment:
#   MANYREACH_API_KEY - API key (loaded from credentials.sh or gopass)
#
# API base: https://api.manyreach.com/api
# Docs: https://docs.manyreach.com
#
# Part of aidevops outreach tooling (t1513)

set -euo pipefail

# Source shared constants (colors, log_* helpers)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Load credentials if available
# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# =============================================================================
# Constants
# =============================================================================

readonly MANYREACH_API_BASE="https://api.manyreach.com/api"
readonly MANYREACH_API_VERSION="v2"
readonly MANYREACH_API_URL="${MANYREACH_API_BASE}/${MANYREACH_API_VERSION}"
readonly VERSION="1.0.0"

# shellcheck disable=SC2034
LOG_PREFIX="manyreach"

# =============================================================================
# Credential Resolution
# =============================================================================

resolve_api_key() {
	# Already set in environment
	if [[ -n "${MANYREACH_API_KEY:-}" ]]; then
		echo "${MANYREACH_API_KEY}"
		return 0
	fi

	# Try gopass (encrypted storage)
	if command -v gopass &>/dev/null; then
		local key=""
		key=$(gopass show -o "aidevops/MANYREACH_API_KEY" 2>/dev/null || true)
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	# Try aidevops secret helper
	if [[ -x "${SCRIPT_DIR}/secret-helper.sh" ]]; then
		local key=""
		key=$("${SCRIPT_DIR}/secret-helper.sh" get MANYREACH_API_KEY 2>/dev/null || true)
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	return 1
}

# =============================================================================
# API Request Helper
# =============================================================================

# Make authenticated ManyReach API request
# Args: method path [json_body]
# Outputs: JSON response to stdout
manyreach_request() {
	local method="$1"
	local path="$2"
	local body="${3:-}"

	local api_key=""
	api_key=$(resolve_api_key) || {
		log_error "ManyReach API key not found"
		log_info "Set with: aidevops secret set MANYREACH_API_KEY"
		log_info "Or add MANYREACH_API_KEY to ~/.config/aidevops/credentials.sh"
		return 1
	}

	local curl_args=(
		-s
		--connect-timeout 15
		--max-time 30
		-H "Authorization: Bearer ${api_key}"
		-H "Content-Type: application/json"
		-H "Accept: application/json"
		-X "${method}"
	)

	if [[ -n "$body" ]]; then
		curl_args+=(-d "${body}")
	fi

	local response=""
	local http_code=""

	# Capture response and HTTP status code separately
	local tmp_file=""
	tmp_file=$(mktemp)
	http_code=$(curl "${curl_args[@]}" -o "${tmp_file}" -w "%{http_code}" \
		"${MANYREACH_API_URL}${path}" 2>/dev/null) || {
		rm -f "${tmp_file}"
		log_error "API request failed: ${method} ${path}"
		return 1
	}
	response=$(cat "${tmp_file}")
	rm -f "${tmp_file}"

	# Handle HTTP error codes
	case "${http_code}" in
	200 | 201 | 204)
		echo "${response}"
		return 0
		;;
	400)
		local msg=""
		msg=$(echo "${response}" | jq -r '.message // .error // "Bad request"' 2>/dev/null || echo "Bad request")
		log_error "Bad request (400): ${msg}"
		return 1
		;;
	401)
		log_error "Unauthorized (401): Invalid or missing API key"
		log_info "Set with: aidevops secret set MANYREACH_API_KEY"
		return 1
		;;
	403)
		log_error "Forbidden (403): Insufficient permissions"
		return 1
		;;
	404)
		log_error "Not found (404): Resource does not exist"
		return 1
		;;
	429)
		log_error "Rate limited (429): Too many requests — wait before retrying"
		return 1
		;;
	*)
		local msg=""
		msg=$(echo "${response}" | jq -r '.message // .error // "Unknown error"' 2>/dev/null || echo "Unknown error")
		log_error "API error (${http_code}): ${msg}"
		return 1
		;;
	esac
}

# =============================================================================
# Output Helpers
# =============================================================================

# Format a campaign record as a readable summary
format_campaign() {
	local json="$1"
	local id name status created_at
	id=$(echo "${json}" | jq -r '.id // "unknown"' 2>/dev/null || echo "unknown")
	name=$(echo "${json}" | jq -r '.name // "unnamed"' 2>/dev/null || echo "unnamed")
	status=$(echo "${json}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
	created_at=$(echo "${json}" | jq -r '.created_at // ""' 2>/dev/null || echo "")
	printf "%-36s  %-30s  %-12s  %s\n" "${id}" "${name}" "${status}" "${created_at}"
	return 0
}

# Format a lead record as a readable summary
format_lead() {
	local json="$1"
	local id email first_name last_name company status
	id=$(echo "${json}" | jq -r '.id // "unknown"' 2>/dev/null || echo "unknown")
	email=$(echo "${json}" | jq -r '.email // ""' 2>/dev/null || echo "")
	first_name=$(echo "${json}" | jq -r '.first_name // ""' 2>/dev/null || echo "")
	last_name=$(echo "${json}" | jq -r '.last_name // ""' 2>/dev/null || echo "")
	company=$(echo "${json}" | jq -r '.company // ""' 2>/dev/null || echo "")
	status=$(echo "${json}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
	printf "%-36s  %-30s  %-20s  %-20s  %s\n" \
		"${id}" "${email}" "${first_name} ${last_name}" "${company}" "${status}"
	return 0
}

# =============================================================================
# Campaign Commands
# =============================================================================

cmd_campaigns() {
	local subcommand="${1:-list}"
	shift 2>/dev/null || true

	case "${subcommand}" in
	list) cmd_campaigns_list "$@" ;;
	get) cmd_campaigns_get "$@" ;;
	create) cmd_campaigns_create "$@" ;;
	pause) cmd_campaigns_pause "$@" ;;
	resume) cmd_campaigns_resume "$@" ;;
	delete) cmd_campaigns_delete "$@" ;;
	*)
		log_error "Unknown campaigns subcommand: ${subcommand}"
		log_info "Valid: list, get, create, pause, resume, delete"
		return 1
		;;
	esac
}

cmd_campaigns_list() {
	local page="1"
	local raw_json="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--page)
			[[ $# -lt 2 ]] && {
				log_error "--page requires a value"
				return 1
			}
			page="$2"
			shift 2
			;;
		--json)
			raw_json="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local response=""
	response=$(manyreach_request "GET" "/campaigns?page=${page}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local count=""
	count=$(echo "${response}" | jq -r '.data | length' 2>/dev/null || echo "0")
	printf "%-36s  %-30s  %-12s  %s\n" "ID" "NAME" "STATUS" "CREATED"
	printf "%s\n" "$(printf '%0.s-' {1..100})"

	echo "${response}" | jq -c '.data[]?' 2>/dev/null | while IFS= read -r campaign; do
		format_campaign "${campaign}"
	done

	log_info "Total: ${count} campaign(s) on page ${page}"
	return 0
}

cmd_campaigns_get() {
	local campaign_id="${1:-}"
	local raw_json="false"

	[[ -z "${campaign_id}" ]] && {
		log_error "Campaign ID required"
		return 1
	}
	[[ "${2:-}" == "--json" ]] && raw_json="true"

	local response=""
	response=$(manyreach_request "GET" "/campaigns/${campaign_id}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local name status from_email total_leads sent_count reply_count
	name=$(echo "${response}" | jq -r '.name // "unnamed"' 2>/dev/null || echo "unnamed")
	status=$(echo "${response}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
	from_email=$(echo "${response}" | jq -r '.from_email // ""' 2>/dev/null || echo "")
	total_leads=$(echo "${response}" | jq -r '.total_leads // 0' 2>/dev/null || echo "0")
	sent_count=$(echo "${response}" | jq -r '.sent_count // 0' 2>/dev/null || echo "0")
	reply_count=$(echo "${response}" | jq -r '.reply_count // 0' 2>/dev/null || echo "0")

	printf "Campaign: %s\n" "${name}"
	printf "ID:       %s\n" "${campaign_id}"
	printf "Status:   %s\n" "${status}"
	printf "From:     %s\n" "${from_email}"
	printf "Leads:    %s\n" "${total_leads}"
	printf "Sent:     %s\n" "${sent_count}"
	printf "Replies:  %s\n" "${reply_count}"
	return 0
}

cmd_campaigns_create() {
	local name=""
	local from_email=""
	local raw_json="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			[[ $# -lt 2 ]] && {
				log_error "--name requires a value"
				return 1
			}
			name="$2"
			shift 2
			;;
		--from-email)
			[[ $# -lt 2 ]] && {
				log_error "--from-email requires a value"
				return 1
			}
			from_email="$2"
			shift 2
			;;
		--json)
			raw_json="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	[[ -z "${name}" ]] && {
		log_error "--name is required"
		return 1
	}

	local body=""
	if [[ -n "${from_email}" ]]; then
		body=$(jq -n --arg n "${name}" --arg e "${from_email}" \
			'{"name": $n, "from_email": $e}')
	else
		body=$(jq -n --arg n "${name}" '{"name": $n}')
	fi

	local response=""
	response=$(manyreach_request "POST" "/campaigns" "${body}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local id=""
	id=$(echo "${response}" | jq -r '.id // "unknown"' 2>/dev/null || echo "unknown")
	log_success "Campaign created: ${name} (ID: ${id})"
	return 0
}

cmd_campaigns_pause() {
	local campaign_id="${1:-}"
	[[ -z "${campaign_id}" ]] && {
		log_error "Campaign ID required"
		return 1
	}

	manyreach_request "POST" "/campaigns/${campaign_id}/pause" >/dev/null || return 1
	log_success "Campaign ${campaign_id} paused"
	return 0
}

cmd_campaigns_resume() {
	local campaign_id="${1:-}"
	[[ -z "${campaign_id}" ]] && {
		log_error "Campaign ID required"
		return 1
	}

	manyreach_request "POST" "/campaigns/${campaign_id}/resume" >/dev/null || return 1
	log_success "Campaign ${campaign_id} resumed"
	return 0
}

cmd_campaigns_delete() {
	local campaign_id="${1:-}"
	[[ -z "${campaign_id}" ]] && {
		log_error "Campaign ID required"
		return 1
	}

	manyreach_request "DELETE" "/campaigns/${campaign_id}" >/dev/null || return 1
	log_success "Campaign ${campaign_id} deleted"
	return 0
}

# =============================================================================
# Lead Commands
# =============================================================================

cmd_leads() {
	local subcommand="${1:-list}"
	shift 2>/dev/null || true

	case "${subcommand}" in
	list) cmd_leads_list "$@" ;;
	get) cmd_leads_get "$@" ;;
	add) cmd_leads_add "$@" ;;
	import) cmd_leads_import "$@" ;;
	unsubscribe) cmd_leads_unsubscribe "$@" ;;
	*)
		log_error "Unknown leads subcommand: ${subcommand}"
		log_info "Valid: list, get, add, import, unsubscribe"
		return 1
		;;
	esac
}

cmd_leads_list() {
	local campaign_id=""
	local page="1"
	local raw_json="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--campaign)
			[[ $# -lt 2 ]] && {
				log_error "--campaign requires a value"
				return 1
			}
			campaign_id="$2"
			shift 2
			;;
		--page)
			[[ $# -lt 2 ]] && {
				log_error "--page requires a value"
				return 1
			}
			page="$2"
			shift 2
			;;
		--json)
			raw_json="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local endpoint=""
	if [[ -n "${campaign_id}" ]]; then
		endpoint="/campaigns/${campaign_id}/leads?page=${page}"
	else
		endpoint="/leads?page=${page}"
	fi

	local response=""
	response=$(manyreach_request "GET" "${endpoint}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local count=""
	count=$(echo "${response}" | jq -r '.data | length' 2>/dev/null || echo "0")
	printf "%-36s  %-30s  %-20s  %-20s  %s\n" "ID" "EMAIL" "NAME" "COMPANY" "STATUS"
	printf "%s\n" "$(printf '%0.s-' {1..120})"

	echo "${response}" | jq -c '.data[]?' 2>/dev/null | while IFS= read -r lead; do
		format_lead "${lead}"
	done

	log_info "Total: ${count} lead(s) on page ${page}"
	return 0
}

cmd_leads_get() {
	local lead_id="${1:-}"
	local raw_json="false"

	[[ -z "${lead_id}" ]] && {
		log_error "Lead ID required"
		return 1
	}
	[[ "${2:-}" == "--json" ]] && raw_json="true"

	local response=""
	response=$(manyreach_request "GET" "/leads/${lead_id}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local email first_name last_name company status
	email=$(echo "${response}" | jq -r '.email // ""' 2>/dev/null || echo "")
	first_name=$(echo "${response}" | jq -r '.first_name // ""' 2>/dev/null || echo "")
	last_name=$(echo "${response}" | jq -r '.last_name // ""' 2>/dev/null || echo "")
	company=$(echo "${response}" | jq -r '.company // ""' 2>/dev/null || echo "")
	status=$(echo "${response}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

	printf "Lead:     %s\n" "${lead_id}"
	printf "Email:    %s\n" "${email}"
	printf "Name:     %s %s\n" "${first_name}" "${last_name}"
	printf "Company:  %s\n" "${company}"
	printf "Status:   %s\n" "${status}"
	return 0
}

cmd_leads_add() {
	local campaign_id=""
	local email=""
	local first_name=""
	local last_name=""
	local company=""
	local raw_json="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--campaign)
			[[ $# -lt 2 ]] && {
				log_error "--campaign requires a value"
				return 1
			}
			campaign_id="$2"
			shift 2
			;;
		--email)
			[[ $# -lt 2 ]] && {
				log_error "--email requires a value"
				return 1
			}
			email="$2"
			shift 2
			;;
		--first-name)
			[[ $# -lt 2 ]] && {
				log_error "--first-name requires a value"
				return 1
			}
			first_name="$2"
			shift 2
			;;
		--last-name)
			[[ $# -lt 2 ]] && {
				log_error "--last-name requires a value"
				return 1
			}
			last_name="$2"
			shift 2
			;;
		--company)
			[[ $# -lt 2 ]] && {
				log_error "--company requires a value"
				return 1
			}
			company="$2"
			shift 2
			;;
		--json)
			raw_json="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	[[ -z "${campaign_id}" ]] && {
		log_error "--campaign is required"
		return 1
	}
	[[ -z "${email}" ]] && {
		log_error "--email is required"
		return 1
	}

	local body=""
	body=$(jq -n \
		--arg e "${email}" \
		--arg fn "${first_name}" \
		--arg ln "${last_name}" \
		--arg c "${company}" \
		'{email: $e, first_name: $fn, last_name: $ln, company: $c}')

	local response=""
	response=$(manyreach_request "POST" "/campaigns/${campaign_id}/leads" "${body}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local id=""
	id=$(echo "${response}" | jq -r '.id // "unknown"' 2>/dev/null || echo "unknown")
	log_success "Lead added: ${email} (ID: ${id})"
	return 0
}

cmd_leads_import() {
	local campaign_id=""
	local csv_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--campaign)
			[[ $# -lt 2 ]] && {
				log_error "--campaign requires a value"
				return 1
			}
			campaign_id="$2"
			shift 2
			;;
		--file)
			[[ $# -lt 2 ]] && {
				log_error "--file requires a value"
				return 1
			}
			csv_file="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	[[ -z "${campaign_id}" ]] && {
		log_error "--campaign is required"
		return 1
	}
	[[ -z "${csv_file}" ]] && {
		log_error "--file is required"
		return 1
	}
	[[ ! -f "${csv_file}" ]] && {
		log_error "File not found: ${csv_file}"
		return 1
	}

	local api_key=""
	api_key=$(resolve_api_key) || {
		log_error "ManyReach API key not found"
		return 1
	}

	local response=""
	response=$(curl -s --connect-timeout 30 --max-time 120 \
		-H "Authorization: Bearer ${api_key}" \
		-F "file=@${csv_file}" \
		"${MANYREACH_API_URL}/campaigns/${campaign_id}/leads/import" 2>/dev/null) || {
		log_error "Import request failed"
		return 1
	}

	local imported failed
	imported=$(echo "${response}" | jq -r '.imported // 0' 2>/dev/null || echo "0")
	failed=$(echo "${response}" | jq -r '.failed // 0' 2>/dev/null || echo "0")
	log_success "Import complete: ${imported} imported, ${failed} failed"
	return 0
}

cmd_leads_unsubscribe() {
	local lead_id="${1:-}"
	[[ -z "${lead_id}" ]] && {
		log_error "Lead ID required"
		return 1
	}

	manyreach_request "POST" "/leads/${lead_id}/unsubscribe" >/dev/null || return 1
	log_success "Lead ${lead_id} unsubscribed"
	return 0
}

# =============================================================================
# Sequence Commands
# =============================================================================

cmd_sequences() {
	local subcommand="${1:-list}"
	shift 2>/dev/null || true

	case "${subcommand}" in
	list) cmd_sequences_list "$@" ;;
	get) cmd_sequences_get "$@" ;;
	add-step) cmd_sequences_add_step "$@" ;;
	*)
		log_error "Unknown sequences subcommand: ${subcommand}"
		log_info "Valid: list, get, add-step"
		return 1
		;;
	esac
}

cmd_sequences_list() {
	local campaign_id=""
	local raw_json="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--campaign)
			[[ $# -lt 2 ]] && {
				log_error "--campaign requires a value"
				return 1
			}
			campaign_id="$2"
			shift 2
			;;
		--json)
			raw_json="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	[[ -z "${campaign_id}" ]] && {
		log_error "--campaign is required"
		return 1
	}

	local response=""
	response=$(manyreach_request "GET" "/campaigns/${campaign_id}/sequences") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	printf "%-36s  %-40s  %s\n" "ID" "SUBJECT" "DELAY (DAYS)"
	printf "%s\n" "$(printf '%0.s-' {1..90})"

	echo "${response}" | jq -c '.data[]?' 2>/dev/null | while IFS= read -r seq; do
		local seq_id subject delay
		seq_id=$(echo "${seq}" | jq -r '.id // "unknown"' 2>/dev/null || echo "unknown")
		subject=$(echo "${seq}" | jq -r '.subject // ""' 2>/dev/null || echo "")
		delay=$(echo "${seq}" | jq -r '.delay_days // 0' 2>/dev/null || echo "0")
		printf "%-36s  %-40s  %s\n" "${seq_id}" "${subject}" "${delay}"
	done
	return 0
}

cmd_sequences_get() {
	local sequence_id="${1:-}"
	local raw_json="false"

	[[ -z "${sequence_id}" ]] && {
		log_error "Sequence ID required"
		return 1
	}
	[[ "${2:-}" == "--json" ]] && raw_json="true"

	local response=""
	response=$(manyreach_request "GET" "/sequences/${sequence_id}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local subject body delay
	subject=$(echo "${response}" | jq -r '.subject // ""' 2>/dev/null || echo "")
	body=$(echo "${response}" | jq -r '.body // ""' 2>/dev/null || echo "")
	delay=$(echo "${response}" | jq -r '.delay_days // 0' 2>/dev/null || echo "0")

	printf "Sequence: %s\n" "${sequence_id}"
	printf "Subject:  %s\n" "${subject}"
	printf "Delay:    %s day(s)\n" "${delay}"
	printf "Body:\n%s\n" "${body}"
	return 0
}

cmd_sequences_add_step() {
	local sequence_id=""
	local subject=""
	local body=""
	local delay_days="0"
	local raw_json="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--sequence)
			[[ $# -lt 2 ]] && {
				log_error "--sequence requires a value"
				return 1
			}
			sequence_id="$2"
			shift 2
			;;
		--subject)
			[[ $# -lt 2 ]] && {
				log_error "--subject requires a value"
				return 1
			}
			subject="$2"
			shift 2
			;;
		--body)
			[[ $# -lt 2 ]] && {
				log_error "--body requires a value"
				return 1
			}
			body="$2"
			shift 2
			;;
		--delay-days)
			[[ $# -lt 2 ]] && {
				log_error "--delay-days requires a value"
				return 1
			}
			delay_days="$2"
			shift 2
			;;
		--json)
			raw_json="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	[[ -z "${sequence_id}" ]] && {
		log_error "--sequence is required"
		return 1
	}
	[[ -z "${subject}" ]] && {
		log_error "--subject is required"
		return 1
	}
	[[ -z "${body}" ]] && {
		log_error "--body is required"
		return 1
	}

	local req_body=""
	req_body=$(jq -n \
		--arg s "${subject}" \
		--arg b "${body}" \
		--argjson d "${delay_days}" \
		'{subject: $s, body: $b, delay_days: $d}')

	local response=""
	response=$(manyreach_request "POST" "/sequences/${sequence_id}/steps" "${req_body}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local id=""
	id=$(echo "${response}" | jq -r '.id // "unknown"' 2>/dev/null || echo "unknown")
	log_success "Sequence step added (ID: ${id})"
	return 0
}

# =============================================================================
# Mailbox Commands
# =============================================================================

cmd_mailboxes() {
	local subcommand="${1:-list}"
	shift 2>/dev/null || true

	case "${subcommand}" in
	list) cmd_mailboxes_list "$@" ;;
	get) cmd_mailboxes_get "$@" ;;
	*)
		log_error "Unknown mailboxes subcommand: ${subcommand}"
		log_info "Valid: list, get"
		return 1
		;;
	esac
}

cmd_mailboxes_list() {
	local raw_json="false"
	[[ "${1:-}" == "--json" ]] && raw_json="true"

	local response=""
	response=$(manyreach_request "GET" "/mailboxes") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	printf "%-36s  %-30s  %-12s  %s\n" "ID" "EMAIL" "STATUS" "WARMUP"
	printf "%s\n" "$(printf '%0.s-' {1..90})"

	echo "${response}" | jq -c '.data[]?' 2>/dev/null | while IFS= read -r mb; do
		local mb_id mb_email mb_status warmup
		mb_id=$(echo "${mb}" | jq -r '.id // "unknown"' 2>/dev/null || echo "unknown")
		mb_email=$(echo "${mb}" | jq -r '.email // ""' 2>/dev/null || echo "")
		mb_status=$(echo "${mb}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
		warmup=$(echo "${mb}" | jq -r '.warmup_enabled // false' 2>/dev/null || echo "false")
		printf "%-36s  %-30s  %-12s  %s\n" "${mb_id}" "${mb_email}" "${mb_status}" "${warmup}"
	done
	return 0
}

cmd_mailboxes_get() {
	local mailbox_id="${1:-}"
	local raw_json="false"

	[[ -z "${mailbox_id}" ]] && {
		log_error "Mailbox ID required"
		return 1
	}
	[[ "${2:-}" == "--json" ]] && raw_json="true"

	local response=""
	response=$(manyreach_request "GET" "/mailboxes/${mailbox_id}") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local mb_email mb_status warmup daily_limit sent_today
	mb_email=$(echo "${response}" | jq -r '.email // ""' 2>/dev/null || echo "")
	mb_status=$(echo "${response}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
	warmup=$(echo "${response}" | jq -r '.warmup_enabled // false' 2>/dev/null || echo "false")
	daily_limit=$(echo "${response}" | jq -r '.daily_limit // 0' 2>/dev/null || echo "0")
	sent_today=$(echo "${response}" | jq -r '.sent_today // 0' 2>/dev/null || echo "0")

	printf "Mailbox:     %s\n" "${mailbox_id}"
	printf "Email:       %s\n" "${mb_email}"
	printf "Status:      %s\n" "${mb_status}"
	printf "Warmup:      %s\n" "${warmup}"
	printf "Daily limit: %s\n" "${daily_limit}"
	printf "Sent today:  %s\n" "${sent_today}"
	return 0
}

# =============================================================================
# Stats Commands
# =============================================================================

cmd_stats() {
	local subcommand="${1:-}"
	shift 2>/dev/null || true

	case "${subcommand}" in
	campaign) cmd_stats_campaign "$@" ;;
	*)
		log_error "Unknown stats subcommand: ${subcommand:-}"
		log_info "Valid: campaign"
		return 1
		;;
	esac
}

cmd_stats_campaign() {
	local campaign_id="${1:-}"
	local raw_json="false"

	[[ -z "${campaign_id}" ]] && {
		log_error "Campaign ID required"
		return 1
	}
	[[ "${2:-}" == "--json" ]] && raw_json="true"

	local response=""
	response=$(manyreach_request "GET" "/campaigns/${campaign_id}/stats") || return 1

	if [[ "${raw_json}" == "true" ]]; then
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 0
	fi

	local sent delivered opened clicked replied bounced unsubscribed
	sent=$(echo "${response}" | jq -r '.sent // 0' 2>/dev/null || echo "0")
	delivered=$(echo "${response}" | jq -r '.delivered // 0' 2>/dev/null || echo "0")
	opened=$(echo "${response}" | jq -r '.opened // 0' 2>/dev/null || echo "0")
	clicked=$(echo "${response}" | jq -r '.clicked // 0' 2>/dev/null || echo "0")
	replied=$(echo "${response}" | jq -r '.replied // 0' 2>/dev/null || echo "0")
	bounced=$(echo "${response}" | jq -r '.bounced // 0' 2>/dev/null || echo "0")
	unsubscribed=$(echo "${response}" | jq -r '.unsubscribed // 0' 2>/dev/null || echo "0")

	printf "Campaign Stats: %s\n" "${campaign_id}"
	printf "%-15s %s\n" "Sent:" "${sent}"
	printf "%-15s %s\n" "Delivered:" "${delivered}"
	printf "%-15s %s\n" "Opened:" "${opened}"
	printf "%-15s %s\n" "Clicked:" "${clicked}"
	printf "%-15s %s\n" "Replied:" "${replied}"
	printf "%-15s %s\n" "Bounced:" "${bounced}"
	printf "%-15s %s\n" "Unsubscribed:" "${unsubscribed}"
	return 0
}

# =============================================================================
# Status Command
# =============================================================================

cmd_status() {
	log_info "ManyReach Helper v${VERSION}"

	# Check API key
	local api_key=""
	if api_key=$(resolve_api_key 2>/dev/null); then
		local key_preview="${api_key:0:8}..."
		log_success "API key configured (${key_preview})"
	else
		log_error "API key not configured"
		log_info "Set with: aidevops secret set MANYREACH_API_KEY"
		return 1
	fi

	# Check jq dependency
	if command -v jq &>/dev/null; then
		log_success "jq available"
	else
		log_error "jq not found — install with: brew install jq"
		return 1
	fi

	# Test API connectivity
	log_info "Testing API connectivity..."
	local response=""
	if response=$(manyreach_request "GET" "/mailboxes" 2>/dev/null); then
		local count=""
		count=$(echo "${response}" | jq -r '.data | length' 2>/dev/null || echo "0")
		log_success "API reachable — ${count} mailbox(es) found"
	else
		log_error "API connectivity test failed"
		return 1
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	sed -n '2,/^set -/p' "$0" | sed '/^set -/d' | sed 's/^# \?//'
	return 0
}

# =============================================================================
# Main Dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "${command}" in
	campaigns) cmd_campaigns "$@" ;;
	leads) cmd_leads "$@" ;;
	sequences) cmd_sequences "$@" ;;
	mailboxes) cmd_mailboxes "$@" ;;
	stats) cmd_stats "$@" ;;
	status) cmd_status ;;
	help | -h | --help) cmd_help ;;
	version | -v | --version)
		echo "manyreach-helper.sh v${VERSION}"
		return 0
		;;
	*)
		log_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
