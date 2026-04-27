#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# =============================================================================
# Case Chase Helper (t2858 — P6b: template-only, opt-in auto-send)
# =============================================================================
# Send routine chaser emails built from deterministic templates.
# No LLM at send time — only verified-data field substitution.
# Per-case opt-in via dossier.toon: chasers_enabled: true.
#
# Usage:
#   case-chase-helper.sh send <case-id> --template <name> [--to <email>]
#                        [--dry-run] [--mailbox <id>] [--repo <path>]
#   case-chase-helper.sh retry <case-id> <message-id>
#   case-chase-helper.sh template add|list|test [options]
#   case-chase-helper.sh help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
EMAIL_SEND_PY="${SCRIPT_DIR}/email_send.py"
CHASE_TMPL_DIR="${SCRIPT_DIR}/../templates/case-chase-templates"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly CASES_DIR_NAME="_cases"
readonly CASE_DOSSIER_FILE="dossier.toon"
readonly CASE_TIMELINE_FILE="timeline.jsonl"
readonly CASE_SOURCES_FILE="sources.toon"
readonly CASE_COMMS_DIR="comms"
readonly CHASE_SENT_FILE="sent.jsonl"
readonly CASE_ARCHIVE_DIR="archived"

# Template placeholder pattern: {{field_name}}
readonly TMPL_PLACEHOLDER_PATTERN='{{[a-zA-Z_][a-zA-Z0-9_]*}}'

# Status constants — centralised to avoid repeated literal violations
readonly CHASE_STATUS_ERROR="error"
readonly CHASE_STATUS_SENT="sent"
readonly CHASE_BOOL_TRUE="true"

# =============================================================================
# Error helpers
# =============================================================================

_err_opt_unknown() {
	local _o="${1:-}"
	print_error "Unknown option: ${_o}"
	return 1
}

_err_case_missing() {
	local _id="${1:-}"
	print_error "Case not found: ${_id}"
	return 1
}

_err_tmpl_dir_missing() {
	print_error "Template directory not found: ${CHASE_TMPL_DIR}"
	return 1
}

# =============================================================================
# Internal helpers
# =============================================================================

_iso_ts_full() {
	date -u '+%Y%m%dT%H%M%SZ'
	return 0
}

_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not found. Install: brew install jq"
		return 1
	fi
	return 0
}

_require_python() {
	if ! command -v python3 >/dev/null 2>&1; then
		print_error "python3 is required but not found."
		return 1
	fi
	return 0
}

# _resolve_cases_dir <repo-path>
_resolve_cases_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${CASES_DIR_NAME}"
	return 0
}

# _case_find <cases-dir> <case-id-or-slug>
# Returns full path; exits 1 if not found.
_case_find() {
	local cases_dir="$1" query="$2"

	if [[ -d "${cases_dir}/${query}" ]]; then
		echo "${cases_dir}/${query}"
		return 0
	fi

	local dir matched=""
	for dir in "${cases_dir}"/case-*-"${query}" "${cases_dir}"/case-*-*"${query}"*; do
		[[ -d "$dir" ]] || continue
		[[ "$dir" == *"/${CASE_ARCHIVE_DIR}/"* ]] && continue
		matched="$dir"
		break
	done

	if [[ -z "$matched" ]]; then
		for dir in "${cases_dir}/${CASE_ARCHIVE_DIR}"/case-*-"${query}" \
			"${cases_dir}/${CASE_ARCHIVE_DIR}"/case-*-*"${query}"*; do
			[[ -d "$dir" ]] || continue
			matched="$dir"
			break
		done
	fi

	if [[ -n "$matched" ]]; then
		echo "$matched"
		return 0
	fi
	return 1
}

# _dossier_load <case-dir> — prints dossier JSON to stdout
_dossier_load() {
	local case_dir="$1"
	local dossier_path="${case_dir}/${CASE_DOSSIER_FILE}"
	if [[ ! -f "$dossier_path" ]]; then
		print_error "Dossier not found: ${dossier_path}"
		return 1
	fi
	jq '.' "$dossier_path"
	return 0
}

# _timeline_append <case-dir> <kind> <actor> <content> [ref]
_timeline_append() {
	local case_dir="$1" kind="$2" actor="$3" content="$4" ref="${5:-}"
	local timeline_path="${case_dir}/${CASE_TIMELINE_FILE}"
	local ts
	ts="$(_iso_ts_full)"
	local event
	event="$(jq -cn \
		--arg ts "$ts" \
		--arg kind "$kind" \
		--arg actor "$actor" \
		--arg content "$content" \
		--arg ref "$ref" \
		'{ts:$ts, kind:$kind, actor:$actor, content:$content, ref:$ref}')"
	echo "$event" >>"$timeline_path"
	return 0
}

# _current_actor — git user name or $USER
_current_actor() {
	local actor
	actor="$(git config user.name 2>/dev/null)" || true
	[[ -z "$actor" ]] && actor="${USER:-unknown}"
	echo "$actor"
	return 0
}

# =============================================================================
# Mailbox config helpers
# =============================================================================

# _mailbox_config_path <repo-path>
# Looks for per-repo _config/mailboxes.json, then global ~/.config/aidevops/mailboxes.json
_mailbox_config_path() {
	local repo_path="${1:-$(pwd)}"
	local per_repo="${repo_path}/_config/mailboxes.json"
	local global_conf="${HOME}/.config/aidevops/mailboxes.json"

	if [[ -f "$per_repo" ]]; then
		echo "$per_repo"
		return 0
	fi
	if [[ -f "$global_conf" ]]; then
		echo "$global_conf"
		return 0
	fi
	return 1
}

# _smtp_settings_for_mailbox <mailboxes-json> <mailbox-id>
# Returns JSON: {host, port, security, user, provider, password_ref}
_smtp_settings_for_mailbox() {
	local mailboxes_json="$1" mailbox_id="$2"
	local providers_file="${SCRIPT_DIR}/../configs/email-providers.json.txt"

	local mailbox_entry
	mailbox_entry="$(jq -r --arg id "$mailbox_id" '.mailboxes[] | select(.id == $id)' "$mailboxes_json" 2>/dev/null)"
	if [[ -z "$mailbox_entry" ]]; then
		print_error "Mailbox not found: ${mailbox_id}"
		return 1
	fi

	local provider
	provider="$(echo "$mailbox_entry" | jq -r '.smtp_provider // .provider // empty')"
	local user
	user="$(echo "$mailbox_entry" | jq -r '.user // empty')"
	local password_ref
	password_ref="$(echo "$mailbox_entry" | jq -r '.password_ref // empty')"

	# Direct SMTP overrides (smtp_host/smtp_port/smtp_security in mailbox entry)
	local smtp_host smtp_port smtp_security
	smtp_host="$(echo "$mailbox_entry" | jq -r '.smtp_host // empty')"
	smtp_port="$(echo "$mailbox_entry" | jq -r '.smtp_port // empty')"
	smtp_security="$(echo "$mailbox_entry" | jq -r '.smtp_security // empty')"

	# Fall back to providers config if not overridden
	if [[ -z "$smtp_host" && -n "$provider" && -f "$providers_file" ]]; then
		smtp_host="$(jq -r --arg p "$provider" '.providers[$p].smtp.host // empty' "$providers_file" 2>/dev/null)"
		smtp_port="$(jq -r --arg p "$provider" '.providers[$p].smtp.port // empty' "$providers_file" 2>/dev/null)"
		smtp_security="$(jq -r --arg p "$provider" '.providers[$p].smtp.security // empty' "$providers_file" 2>/dev/null)"
	fi

	if [[ -z "$smtp_host" ]]; then
		print_error "Cannot determine SMTP host for mailbox: ${mailbox_id}. Add smtp_host to mailbox entry."
		return 1
	fi

	jq -n \
		--arg host "$smtp_host" \
		--arg port "${smtp_port:-465}" \
		--arg security "${smtp_security:-TLS}" \
		--arg user "$user" \
		--arg provider "$provider" \
		--arg password_ref "$password_ref" \
		'{host:$host, port:($port|tonumber), security:$security, user:$user, provider:$provider, password_ref:$password_ref}'
	return 0
}

# _resolve_password <password_ref>
# Resolves gopass: or env: references. NEVER logs the value.
_resolve_password() {
	local password_ref="$1"
	local password=""

	if [[ "$password_ref" == gopass:* ]]; then
		local gopass_path="${password_ref#gopass:}"
		if command -v gopass >/dev/null 2>&1; then
			password="$(gopass show -o "$gopass_path" 2>/dev/null)" || {
				print_error "Failed to retrieve password from gopass: ${gopass_path}"
				return 1
			}
		else
			print_error "gopass not installed. Cannot resolve: ${password_ref}"
			return 1
		fi
	elif [[ "$password_ref" == env:* ]]; then
		local env_var="${password_ref#env:}"
		password="${!env_var:-}"
		if [[ -z "$password" ]]; then
			print_error "Environment variable not set: ${env_var}"
			return 1
		fi
	elif [[ -n "$password_ref" ]]; then
		# Assume literal (not recommended, but allowed for testing)
		password="$password_ref"
	fi

	printf '%s' "$password"
	return 0
}

# =============================================================================
# Template helpers
# =============================================================================

# _tmpl_path <name>
# Resolves template file path (with or without .eml.tmpl extension).
_tmpl_path() {
	local name="$1"
	local tmpl_dir
	tmpl_dir="$(cd "${CHASE_TMPL_DIR}" && pwd)" 2>/dev/null || {
		_err_tmpl_dir_missing
		return 1
	}

	local candidate
	for candidate in \
		"${tmpl_dir}/${name}" \
		"${tmpl_dir}/${name}.eml.tmpl" \
		"${tmpl_dir}/${name}.tmpl"; do
		if [[ -f "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done

	print_error "Template not found: ${name} (looked in ${tmpl_dir})"
	return 1
}

# _tmpl_placeholders <tmpl-path>
# Lists all {{field}} placeholders in a template (excluding comment lines starting with #).
_tmpl_placeholders() {
	local tmpl_path="$1"
	grep -oE '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' "$tmpl_path" \
		| grep -v '^#' \
		| sed 's/[{}]//g' \
		| sort -u
	return 0
}

# _tmpl_substitute <tmpl-path> <fields-json>
# Substitutes all {{field}} placeholders using fields-json {"field": "value", ...}.
# Returns 0 on success (stdout = substituted content).
# Returns 1 if any placeholder remains unresolved.
_tmpl_substitute() {
	local tmpl_path="$1"
	local fields_json="$2"

	# Read template, skip comment lines (starting with #)
	local content
	content="$(grep -v '^#' "$tmpl_path")"

	# Resolve each placeholder
	local missing_fields=()
	local field value

	while IFS= read -r field; do
		[[ -z "$field" ]] && continue
		value="$(echo "$fields_json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null)" || value=""
		if [[ -z "$value" ]]; then
			missing_fields+=("$field")
		else
			content="${content//\{\{${field}\}\}/${value}}"
		fi
	done < <(_tmpl_placeholders "$tmpl_path")

	if [[ ${#missing_fields[@]} -gt 0 ]]; then
		print_error "Missing required template fields:"
		local f
		for f in "${missing_fields[@]}"; do
			print_error "  - {{${f}}}"
		done
		return 1
	fi

	echo "$content"
	return 0
}

# _parse_eml_headers <substituted-content>
# Parses RFC 5322 header lines from substituted template.
# Returns JSON: {from, to, subject, body}
_parse_eml_headers() {
	local content="$1"
	local from_val="" to_val="" subject_val="" body_val=""
	local in_headers=true

	while IFS= read -r line; do
		if [[ "$in_headers" == true ]]; then
			if [[ -z "$line" ]]; then
				in_headers=false
				continue
			fi
			if [[ "$line" =~ ^From:[[:space:]]*(.*) ]]; then
				from_val="${BASH_REMATCH[1]}"
			elif [[ "$line" =~ ^To:[[:space:]]*(.*) ]]; then
				to_val="${BASH_REMATCH[1]}"
			elif [[ "$line" =~ ^Subject:[[:space:]]*(.*) ]]; then
				subject_val="${BASH_REMATCH[1]}"
			fi
		else
			body_val="${body_val}${line}
"
		fi
	done <<<"$content"

	# Trim trailing newline from body
	body_val="${body_val%$'\n'}"

	jq -n \
		--arg from "$from_val" \
		--arg to "$to_val" \
		--arg subject "$subject_val" \
		--arg body "$body_val" \
		'{from:$from, to:$to, subject:$subject, body:$body}'
	return 0
}

# =============================================================================
# Field resolution
# =============================================================================

# _resolve_fields <case-dir> <template-name> <to-email> <mailbox-id> <repo-path>
# Builds a JSON object of all substitution fields.
_resolve_fields() {
	local case_dir="$1" tmpl_name="$2" to_email="$3" mailbox_id="$4" repo_path="$5"

	_require_jq || return 1

	local dossier
	dossier="$(_dossier_load "$case_dir")" || return 1

	# Case fields
	local case_id kind
	case_id="$(echo "$dossier" | jq -r '.id')"
	kind="$(echo "$dossier" | jq -r '.kind')"

	# First deadline fields
	local due_date deadline_label
	due_date="$(echo "$dossier" | jq -r '(.deadlines | sort_by(.date) | first | .date) // empty')"
	deadline_label="$(echo "$dossier" | jq -r '(.deadlines | sort_by(.date) | first | .label) // empty')"

	# Recipient: first non-self party or the --to flag
	local recipient_name="" recipient_email_auto=""
	if [[ -n "$to_email" ]]; then
		recipient_email_auto="$to_email"
		# Try to look up name from parties
		recipient_name="$(echo "$dossier" | jq -r \
			--arg email "$to_email" \
			'.parties[] | select(.email == $email) | .name' 2>/dev/null | head -1)" || true
	else
		# Auto-detect: first party that is not "self"
		local first_party
		first_party="$(echo "$dossier" | jq -r '.parties[] | select(.role != "self") | @json' 2>/dev/null | head -1)" || true
		if [[ -n "$first_party" ]]; then
			recipient_name="$(echo "$first_party" | jq -r '.name // empty')"
			recipient_email_auto="$(echo "$first_party" | jq -r '.email // empty')"
		fi
	fi

	# Sender from mailboxes.json
	local sender_email="" sender_name=""
	local mailboxes_file
	if mailboxes_file="$(_mailbox_config_path "$repo_path" 2>/dev/null)"; then
		sender_email="$(jq -r --arg id "$mailbox_id" '.mailboxes[] | select(.id == $id) | .user // empty' "$mailboxes_file" 2>/dev/null)" || true
		sender_name="$(jq -r --arg id "$mailbox_id" '.mailboxes[] | select(.id == $id) | .display_name // .user // empty' "$mailboxes_file" 2>/dev/null)" || true
	fi

	# Invoice fields from sources.toon (kind: invoice) → extracted.json
	local invoice_number="" invoice_date="" amount="" currency=""
	local sources_file="${case_dir}/${CASE_SOURCES_FILE}"
	if [[ -f "$sources_file" ]]; then
		local invoice_source_id
		invoice_source_id="$(jq -r '.[] | select(.kind == "invoice") | .id' "$sources_file" 2>/dev/null | head -1)" || true
		if [[ -n "$invoice_source_id" ]]; then
			local extracted_json="${repo_path}/_knowledge/sources/${invoice_source_id}/extracted.json"
			if [[ -f "$extracted_json" ]]; then
				invoice_number="$(jq -r '.invoice_number // empty' "$extracted_json" 2>/dev/null)" || true
				invoice_date="$(jq -r '.invoice_date // empty' "$extracted_json" 2>/dev/null)" || true
				amount="$(jq -r '.amount // empty' "$extracted_json" 2>/dev/null)" || true
				currency="$(jq -r '.currency // empty' "$extracted_json" 2>/dev/null)" || true
			fi
		fi
	fi

	# Current date for receipt acknowledgement
	local received_date
	received_date="$(date -u '+%Y-%m-%d')"

	# Build fields JSON
	jq -n \
		--arg case_id "$case_id" \
		--arg kind "$kind" \
		--arg due_date "$due_date" \
		--arg deadline_label "$deadline_label" \
		--arg recipient_name "${recipient_name:-${recipient_email_auto}}" \
		--arg recipient_email "${recipient_email_auto}" \
		--arg sender_email "$sender_email" \
		--arg sender_name "$sender_name" \
		--arg invoice_number "$invoice_number" \
		--arg invoice_date "$invoice_date" \
		--arg amount "$amount" \
		--arg currency "$currency" \
		--arg received_date "$received_date" \
		'{
			case_id: $case_id,
			kind: $kind,
			due_date: $due_date,
			deadline_label: $deadline_label,
			recipient_name: $recipient_name,
			recipient_email: $recipient_email,
			sender_email: $sender_email,
			sender_name: $sender_name,
			invoice_number: $invoice_number,
			invoice_date: $invoice_date,
			amount: $amount,
			currency: $currency,
			received_date: $received_date
		}'
	return 0
}

# =============================================================================
# Chase send audit
# =============================================================================

# _sent_jsonl_append <case-dir> <record-json>
_sent_jsonl_append() {
	local case_dir="$1" record="$2"
	local comms_dir="${case_dir}/${CASE_COMMS_DIR}"
	mkdir -p "$comms_dir"
	echo "$record" >>"${comms_dir}/${CHASE_SENT_FILE}"
	return 0
}

# _consecutive_failures <case-dir>
# Returns count of consecutive error records at tail of sent.jsonl
_consecutive_failures() {
	local case_dir="$1"
	local sent_file="${case_dir}/${CASE_COMMS_DIR}/${CHASE_SENT_FILE}"
	[[ ! -f "$sent_file" ]] && echo 0 && return 0

	local count=0
	while IFS= read -r line; do
		local status
		status="$(echo "$line" | jq -r '.status // empty' 2>/dev/null)" || status="${CHASE_STATUS_SENT}"
		[[ -z "$status" ]] && status="${CHASE_STATUS_SENT}"
		if [[ "$status" == "${CHASE_STATUS_ERROR}" ]]; then
			count=$((count + 1))
		else
			count=0
		fi
	done <"$sent_file"
	echo "$count"
	return 0
}

# =============================================================================
# Opt-in gate
# =============================================================================

# _check_opt_in <dossier-json> <force>
# Returns 0 if chasers_enabled, 1 otherwise (with message).
_check_opt_in() {
	local dossier="$1" force="$2"
	local chasers_enabled
	chasers_enabled="$(echo "$dossier" | jq -r '.chasers_enabled // false')"

	if [[ "$chasers_enabled" == "${CHASE_BOOL_TRUE}" ]]; then
		return 0
	fi

	if [[ "$force" == "${CHASE_BOOL_TRUE}" && "$chasers_enabled" == "false-with-force-allowed" ]]; then
		print_warning "Chaser sent with --force on case with chasers_enabled: false-with-force-allowed"
		return 0
	fi

	local case_id
	case_id="$(echo "$dossier" | jq -r '.id')"
	print_error "Chasers not enabled for case: ${case_id}"
	print_error "Set dossier.toon: chasers_enabled: true to enable automated chasers."
	print_error "Use --force only when chasers_enabled is 'false-with-force-allowed'."
	return 1
}

# =============================================================================
# cmd_send — send a chaser from a template
# =============================================================================

cmd_send() {
	_require_jq || return 1
	_require_python || return 1

	local case_id="" tmpl_name="" to_email="" mailbox_id=""
	local dry_run=false force=false repo_path="" json_mode=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--template | -t) tmpl_name="$_nxt"; shift 2 ;;
		--to) to_email="$_nxt"; shift 2 ;;
		--mailbox) mailbox_id="$_nxt"; shift 2 ;;
		--dry-run) dry_run=true; shift ;;
		--force) force=true; shift ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$case_id" ]] && { print_error "Usage: case-chase send <case-id> --template <name>"; return 1; }
	[[ -z "$tmpl_name" ]] && { print_error "--template is required"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	# Opt-in gate
	local dossier
	dossier="$(_dossier_load "$case_dir")" || return 1
	_check_opt_in "$dossier" "$force" || return 1

	# Resolve mailbox
	if [[ -z "$mailbox_id" ]]; then
		local mailboxes_file
		if mailboxes_file="$(_mailbox_config_path "$repo_path" 2>/dev/null)"; then
			mailbox_id="$(jq -r '.mailboxes[0].id // empty' "$mailboxes_file" 2>/dev/null)" || true
		fi
	fi
	[[ -z "$mailbox_id" ]] && {
		print_error "No mailbox configured. Set up _config/mailboxes.json or ~/.config/aidevops/mailboxes.json"
		return 1
	}

	# Resolve template path
	local tmpl_path
	tmpl_path="$(_tmpl_path "$tmpl_name")" || return 1

	# Resolve fields
	local fields_json
	fields_json="$(_resolve_fields "$case_dir" "$tmpl_name" "$to_email" "$mailbox_id" "$repo_path")" || return 1

	# Substitute template
	local substituted
	substituted="$(_tmpl_substitute "$tmpl_path" "$fields_json")" || {
		print_error "Template substitution failed — missing fields listed above. No email sent."
		return 1
	}

	# Parse headers from substituted content
	local parsed_headers
	parsed_headers="$(_parse_eml_headers "$substituted")" || return 1

	local from_addr to_addr subject body
	from_addr="$(echo "$parsed_headers" | jq -r '.from')"
	to_addr="$(echo "$parsed_headers" | jq -r '.to')"
	subject="$(echo "$parsed_headers" | jq -r '.subject')"
	body="$(echo "$parsed_headers" | jq -r '.body')"

	# Validate parsed headers
	[[ -z "$from_addr" ]] && { print_error "Template missing From: header after substitution"; return 1; }
	[[ -z "$to_addr" ]] && { print_error "Template missing To: header (or --to not provided with recipient)"; return 1; }
	[[ -z "$subject" ]] && { print_error "Template missing Subject: header after substitution"; return 1; }

	# Dry run
	if [[ "$dry_run" == true ]]; then
		print_info "DRY RUN — would send:"
		echo "From: ${from_addr}"
		echo "To: ${to_addr}"
		echo "Subject: ${subject}"
		echo ""
		echo "$body"
		if [[ "$json_mode" == true ]]; then
			jq -n \
				--arg dry_run "${CHASE_BOOL_TRUE}" \
				--arg from "$from_addr" \
				--arg to "$to_addr" \
				--arg subject "$subject" \
				--arg body "$body" \
				'{dry_run:true, from:$from, to:$to, subject:$subject, body:$body}'
		fi
		return 0
	fi

	# Get SMTP settings
	local mailboxes_file smtp_settings
	mailboxes_file="$(_mailbox_config_path "$repo_path" 2>/dev/null)" || {
		print_error "No mailboxes config found. Cannot send."
		return 1
	}
	smtp_settings="$(_smtp_settings_for_mailbox "$mailboxes_file" "$mailbox_id")" || return 1

	local smtp_host smtp_port smtp_security smtp_user password_ref
	smtp_host="$(echo "$smtp_settings" | jq -r '.host')"
	smtp_port="$(echo "$smtp_settings" | jq -r '.port')"
	smtp_security="$(echo "$smtp_settings" | jq -r '.security')"
	smtp_user="$(echo "$smtp_settings" | jq -r '.user')"
	password_ref="$(echo "$smtp_settings" | jq -r '.password_ref // empty')"

	# Resolve password (never log it)
	local password=""
	if [[ -n "$password_ref" ]]; then
		password="$(_resolve_password "$password_ref")" || return 1
	fi

	# Send via email_send.py
	local send_result
	send_result="$(printf '%s' "$password" | python3 "$EMAIL_SEND_PY" \
		--smtp-host "$smtp_host" \
		--smtp-port "$smtp_port" \
		--smtp-security "$smtp_security" \
		--smtp-user "$smtp_user" \
		--from-addr "$from_addr" \
		--to-addr "$to_addr" \
		--subject "$subject" \
		--body "$body")" || {

		# On send failure: record error, check consecutive failures
		local ts actor case_id_val
		ts="$(_iso_ts_full)"
		actor="$(_current_actor)"
		case_id_val="$(echo "$dossier" | jq -r '.id')"

		local error_record
		error_record="$(jq -n \
			--arg ts "$ts" \
			--arg case_id "$case_id_val" \
			--arg template "$tmpl_name" \
			--arg recipient "$to_addr" \
			--arg mailbox "$mailbox_id" \
			--arg status "${CHASE_STATUS_ERROR}" \
			--arg error "SMTP send failed" \
			'{ts:$ts, case_id:$case_id, template:$template, recipient:$recipient,
			  mailbox_id:$mailbox, status:$status, error:$error, retry_allowed:true}')"
		_sent_jsonl_append "$case_dir" "$error_record"
		_timeline_append "$case_dir" "chase_error" "$actor" \
			"Chase send failed: ${tmpl_name} to ${to_addr}" ""

		# Check consecutive failures
		local fail_count
		fail_count="$(_consecutive_failures "$case_dir")"
		if [[ "$fail_count" -ge 2 ]]; then
			print_error "Two consecutive chase send failures — setting case to hold and firing alarm"
			# Set case status to hold
			local updated_dossier
			updated_dossier="$(echo "$dossier" | jq '.status = "hold"')"
			echo "$updated_dossier" >"${case_dir}/${CASE_DOSSIER_FILE}"
			_timeline_append "$case_dir" "status_change" "$actor" \
				"Status changed: open → hold. Reason: consecutive chase send failures" ""

			# Fire alarm if case-alarm-helper.sh is available
			local alarm_helper="${SCRIPT_DIR}/case-alarm-helper.sh"
			if [[ -x "$alarm_helper" ]]; then
				"$alarm_helper" fire "$case_id_val" --reason "chase send failure" || true
			fi
		fi

		print_error "Chase send failed for case: ${case_id_val}"
		return 1
	}

	# Check if send_result contains an error
	local send_error
	send_error="$(echo "$send_result" | jq -r '.error // empty' 2>/dev/null)" || send_error=""
	if [[ -n "$send_error" ]]; then
		print_error "SMTP error: ${send_error}"
		return 1
	fi

	# Success: record to sent.jsonl and timeline
	local message_id sent_at
	message_id="$(echo "$send_result" | jq -r '.message_id // empty')"
	sent_at="$(echo "$send_result" | jq -r '.sent_at // empty')"

	local actor case_id_val
	actor="$(_current_actor)"
	case_id_val="$(echo "$dossier" | jq -r '.id')"

	local audit_record
	audit_record="$(jq -n \
		--arg ts "$sent_at" \
		--arg case_id "$case_id_val" \
		--arg template "$tmpl_name" \
		--arg recipient "$to_addr" \
		--arg mailbox "$mailbox_id" \
		--arg message_id "$message_id" \
		--arg status "${CHASE_STATUS_SENT}" \
		'{ts:$ts, case_id:$case_id, template:$template, recipient:$recipient,
		  mailbox_id:$mailbox, message_id:$message_id, status:$status}')"
	_sent_jsonl_append "$case_dir" "$audit_record"

	local ref="${CASE_COMMS_DIR}/${CHASE_SENT_FILE}"
	_timeline_append "$case_dir" "chase_sent" "$actor" \
		"Chase sent: ${tmpl_name} to ${to_addr} (${message_id})" "$ref"

	if [[ "$json_mode" == true ]]; then
		echo "$audit_record"
	else
		print_success "Chase sent: ${tmpl_name} → ${to_addr}"
		echo "  Message-ID: ${message_id}"
		echo "  Sent at:    ${sent_at}"
		echo "  Audit log:  ${case_dir}/${CASE_COMMS_DIR}/${CHASE_SENT_FILE}"
	fi
	return 0
}

# =============================================================================
# cmd_retry — retry a failed send by message_id
# =============================================================================

cmd_retry() {
	_require_jq || return 1

	local case_id="" message_id="" repo_path="" json_mode=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) [[ -z "$case_id" ]] && { case_id="$_cur"; shift; } || { message_id="$_cur"; shift; } ;;
		esac
	done

	[[ -z "$case_id" || -z "$message_id" ]] && {
		print_error "Usage: case-chase retry <case-id> <message-id>"
		return 1
	}
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local cases_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	local case_dir
	case_dir="$(_case_find "$cases_dir" "$case_id")" || {
		_err_case_missing "$case_id"
		return 1
	}

	local sent_file="${case_dir}/${CASE_COMMS_DIR}/${CHASE_SENT_FILE}"
	[[ ! -f "$sent_file" ]] && { print_error "No sent log for case: ${case_id}"; return 1; }

	# Find error record with matching context (message_id or most recent error)
	local error_entry
	# jq filters use shell variables for status to avoid repeated literal violations
	local _jq_status_err="${CHASE_STATUS_ERROR}"
	error_entry="$(jq -r --arg mid "$message_id" --arg stat "$_jq_status_err" \
		'[.] | last | select(.status == $stat and .message_id == $mid)' \
		"$sent_file" 2>/dev/null)" || error_entry=""

	if [[ -z "$error_entry" ]]; then
		# Find last error entry regardless of message_id
		error_entry="$(jq -rs --arg stat "$_jq_status_err" \
			'last | select(.status == $stat)' \
			"$sent_file" 2>/dev/null)" || error_entry=""
	fi

	[[ -z "$error_entry" ]] && {
		print_error "No error record found for message-id: ${message_id}"
		return 1
	}

	local tmpl_name to_addr mailbox_id
	tmpl_name="$(echo "$error_entry" | jq -r '.template // empty')"
	to_addr="$(echo "$error_entry" | jq -r '.recipient // empty')"
	mailbox_id="$(echo "$error_entry" | jq -r '.mailbox_id // empty')"

	[[ -z "$tmpl_name" ]] && { print_error "Cannot determine template from error record"; return 1; }

	print_info "Retrying chase: ${tmpl_name} to ${to_addr}"
	local -a retry_args=(
		"$case_id"
		--template "$tmpl_name"
		--to "$to_addr"
		--mailbox "$mailbox_id"
		--repo "$repo_path"
	)
	[[ "$json_mode" == true ]] && retry_args+=(--json)
	cmd_send "${retry_args[@]}"
	return $?
}

# =============================================================================
# cmd_template — manage chase templates
# =============================================================================

cmd_template() {
	local action="${1:-list}"
	shift || true

	case "$action" in
	add) _cmd_template_add "$@" ;;
	list | ls) _cmd_template_list "$@" ;;
	test | dry-run) _cmd_template_test "$@" ;;
	*) print_error "Usage: case-chase template add|list|test [options]"; return 1 ;;
	esac
	return 0
}

_cmd_template_list() {
	local tmpl_dir
	tmpl_dir="$(cd "${CHASE_TMPL_DIR}" && pwd)" 2>/dev/null || {
		_err_tmpl_dir_missing
		return 1
	}

	local found=false
	printf '%-36s %s\n' "TEMPLATE" "DESCRIPTION"
	printf '%s\n' "$(printf '%.0s-' {1..60})"

	local tmpl_file name description
	for tmpl_file in "${tmpl_dir}"/*.eml.tmpl "${tmpl_dir}"/*.tmpl; do
		[[ -f "$tmpl_file" ]] || continue
		name="$(basename "$tmpl_file" .eml.tmpl)"
		name="$(basename "$name" .tmpl)"
		# Description is the first comment line (# description: ...)
		description="$(grep -m1 '^# description:' "$tmpl_file" | sed 's/^# description:[[:space:]]*//')" || description=""
		[[ -z "$description" ]] && description="(no description)"
		printf '%-36s %s\n' "$name" "$description"
		found=true
	done

	if [[ "$found" == false ]]; then
		echo "No templates found in: ${tmpl_dir}"
	fi
	return 0
}

_cmd_template_add() {
	local name=""
	local tmpl_dir
	tmpl_dir="$(cd "${CHASE_TMPL_DIR}" && pwd)" 2>/dev/null || {
		_err_tmpl_dir_missing
		return 1
	}

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}"
		case "$_cur" in
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) name="$_cur"; shift ;;
		esac
	done

	[[ -z "$name" ]] && { print_error "Usage: case-chase template add <name>"; return 1; }

	local tmpl_path="${tmpl_dir}/${name}.eml.tmpl"
	if [[ -f "$tmpl_path" ]]; then
		print_error "Template already exists: ${tmpl_path}"
		return 1
	fi

	# Write a skeleton template
	cat >"$tmpl_path" <<'SKELETON'
# description: (describe this template in one line)
From: {{sender_email}}
To: {{recipient_email}}
Subject: (your subject here)

Dear {{recipient_name}},

(Your message here. Use {{field_name}} for substitution fields.)

Regards,
{{sender_name}}
SKELETON

	# Open in editor if available
	local editor="${EDITOR:-vi}"
	if command -v "$editor" >/dev/null 2>&1; then
		"$editor" "$tmpl_path"
	else
		print_info "Template created: ${tmpl_path}"
		print_info "Open and edit it before use."
	fi

	# Validate: check RFC 5322 required headers
	if ! grep -q '^From:' "$tmpl_path" || ! grep -q '^To:' "$tmpl_path" || ! grep -q '^Subject:' "$tmpl_path"; then
		print_error "Template is missing required RFC 5322 headers (From, To, Subject)."
		print_error "Fix: ${tmpl_path}"
		return 1
	fi

	# Validate placeholder syntax
	if grep -oE '\{[^{][^}]*\}' "$tmpl_path" | grep -qv '^#'; then
		print_warning "Template may contain single-brace placeholders — use {{field_name}} not {field_name}"
	fi

	print_success "Template saved: ${tmpl_path}"
	return 0
}

_cmd_template_test() {
	_require_jq || return 1

	local case_id="" tmpl_name="" to_email="" mailbox_id="" repo_path=""

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--case) case_id="$_nxt"; shift 2 ;;
		--template | -t) tmpl_name="$_nxt"; shift 2 ;;
		--to) to_email="$_nxt"; shift 2 ;;
		--mailbox) mailbox_id="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) shift ;;
		esac
	done

	[[ -z "$case_id" ]] && { print_error "--case is required for template test"; return 1; }
	[[ -z "$tmpl_name" ]] && { print_error "--template is required"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	# Delegate to cmd_send with --dry-run
	local -a test_args=(
		"$case_id"
		--template "$tmpl_name"
		--dry-run
		--repo "$repo_path"
	)
	[[ -n "$to_email" ]] && test_args+=(--to "$to_email")
	[[ -n "$mailbox_id" ]] && test_args+=(--mailbox "$mailbox_id")
	cmd_send "${test_args[@]}"
	return $?
}

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	cat <<'HELP'
Case Chase Helper — send deterministic chaser emails from templates (t2858)

Usage: case-chase-helper.sh <command> [args] [options]

Commands:
  send <case-id> --template <name>    Substitute fields and send via SMTP
  retry <case-id> <message-id>        Retry a failed send
  template list                       List available templates with descriptions
  template add <name>                 Create a new template (opens editor)
  template test --case <id> --template <name>   Dry-run: show substituted email
  help                                Show this help

Send options:
  --template <name>    Template name (from _config/case-chase-templates/)
  --to <email>         Override recipient email (default: auto-detected from parties)
  --mailbox <id>       Mailbox ID from mailboxes.json (default: first mailbox)
  --dry-run            Print substituted email to stdout, do not send
  --force              Override opt-in gate (requires chasers_enabled: false-with-force-allowed)
  --json               Machine-readable JSON output
  --repo <path>        Target repo path (default: current directory)

Opt-in gate:
  By default, chasers are DISABLED per case. Set in dossier.toon:
    chasers_enabled: true         — allow automated chasers
    chasers_enabled: false        — deny (default)
    chasers_enabled: false-with-force-allowed — deny but allow --force override

Templates:
  Located at: .agents/templates/case-chase-templates/<name>.eml.tmpl
  Format: RFC 5322 headers (From/To/Subject) followed by blank line then body.
  Placeholders: {{field_name}} — substituted from dossier, invoice, mailbox.

Available fields:
  {{case_id}}         Case identifier
  {{kind}}            Case kind (dispute, contract, ...)
  {{due_date}}        Next deadline date (ISO)
  {{deadline_label}}  Next deadline label
  {{recipient_name}}  Recipient party name
  {{recipient_email}} Recipient party email
  {{sender_email}}    Mailbox user (From address)
  {{sender_name}}     Mailbox display name
  {{invoice_number}}  Invoice number (from attached invoice source)
  {{invoice_date}}    Invoice date
  {{amount}}          Invoice amount
  {{currency}}        Invoice currency
  {{received_date}}   Today's date (for receipt acknowledgement)

Audit:
  Each send records to: _cases/<case>/comms/sent.jsonl
  Timeline entry added: kind=chase_sent (or chase_error on failure)

Failure handling:
  First failure: logged to sent.jsonl with status=error, retry_allowed=true
  Second consecutive failure: case set to hold + alarm fired (if case-alarm-helper.sh available)

Examples:
  case-chase-helper.sh send case-2026-0001-acme --template payment-reminder
  case-chase-helper.sh send case-2026-0001-acme --template payment-reminder --dry-run
  case-chase-helper.sh template test --case case-2026-0001-acme --template payment-reminder
  case-chase-helper.sh template list
  case-chase-helper.sh template add my-custom-chaser
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	send) cmd_send "$@" ;;
	retry) cmd_retry "$@" ;;
	template | chase-template) cmd_template "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
