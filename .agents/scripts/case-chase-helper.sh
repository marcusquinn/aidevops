#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# =============================================================================
# Case Chase Helper (t2858)
# =============================================================================
# Template-only, opt-in auto-send chaser emails for case management.
# No LLM at send time — only verified dossier data field substitution.
#
# Usage:
#   case-chase-helper.sh send <case-id> --template <name> [--to <email>] [--dry-run]
#   case-chase-helper.sh retry <case-id> <message-id>
#   case-chase-helper.sh template add|list|test [options]
#   case-chase-helper.sh help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly CHASE_CASES_DIR_NAME="_cases"
readonly CHASE_TEMPLATES_SUBDIR="case-chase-templates"
readonly CHASE_DOSSIER_FILE="dossier.toon"
readonly CHASE_SOURCES_FILE="sources.toon"
readonly CHASE_TIMELINE_FILE="timeline.jsonl"
readonly CHASE_SENT_LOGFILE="comms/sent.jsonl"
readonly CHASE_COMMS_DIR="comms"

# Role / status constants — referenced via variable to avoid repeated literals
readonly _CHASE_ROLE_SELF="self"
readonly _CHASE_ROLE_SENDER="sender"
readonly _CHASE_ROLE_USER="user"
readonly _CHASE_STATUS_ERROR="error"

# =============================================================================
# Utility helpers
# =============================================================================

_chase_iso_ts() {
	date -u '+%Y%m%dT%H%M%SZ'
	return 0
}

_chase_require_tools() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required. Install: brew install jq"
		return 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		print_error "python3 is required."
		return 1
	fi
	return 0
}

_chase_current_actor() {
	local actor
	actor=$(git config user.name 2>/dev/null) || true
	[[ -z "$actor" ]] && actor="${USER:-unknown}"
	echo "$actor"
	return 0
}

_chase_err_case_not_found() {
	local _id="$1"
	print_error "Case not found: ${_id}"
	return 1
}

# =============================================================================
# Case / path finders
# =============================================================================

_chase_cases_dir() {
	local repo_path="$1"
	echo "${repo_path}/${CHASE_CASES_DIR_NAME}"
	return 0
}

_chase_templates_dir() {
	local repo_path="$1"
	echo "${repo_path}/_config/${CHASE_TEMPLATES_SUBDIR}"
	return 0
}

_chase_case_find() {
	local cases_dir="$1" query="$2"

	if [[ -d "${cases_dir}/${query}" ]]; then
		echo "${cases_dir}/${query}"
		return 0
	fi

	local dir matched=""
	for dir in "${cases_dir}"/case-*-"${query}" "${cases_dir}"/case-*-*"${query}"*; do
		[[ -d "$dir" ]] || continue
		[[ "$dir" == *"/archived/"* ]] && continue
		matched="$dir"
		break
	done

	if [[ -z "$matched" ]]; then
		for dir in "${cases_dir}/archived"/case-*-"${query}" \
			"${cases_dir}/archived"/case-*-*"${query}"*; do
			[[ -d "$dir" ]] || continue
			matched="$dir"
			break
		done
	fi

	[[ -n "$matched" ]] && echo "$matched" && return 0
	return 1
}

_chase_locate_case() {
	local repo_path="$1" case_id="$2"
	local cases_dir
	cases_dir=$(_chase_cases_dir "$repo_path")
	_chase_case_find "$cases_dir" "$case_id"
	return $?
}

_chase_find_template() {
	local repo_path="$1" name="$2"
	local tdir
	tdir=$(_chase_templates_dir "$repo_path")

	local candidate
	candidate="${tdir}/${name}.eml.tmpl"
	[[ -f "$candidate" ]] && echo "$candidate" && return 0
	candidate="${tdir}/${name}"
	[[ -f "$candidate" ]] && echo "$candidate" && return 0
	return 1
}

_chase_sent_log_path() {
	local case_dir="$1"
	echo "${case_dir}/${CHASE_SENT_LOGFILE}"
	return 0
}

_chase_extract_placeholders() {
	local template_path="$1"
	grep -oE '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' "$template_path" \
		| sed 's/{{//;s/}}//' | sort -u
	return 0
}

# =============================================================================
# Opt-in gate
# =============================================================================

_chase_check_opt_in() {
	local case_dir="$1" force="$2"
	local dossier="${case_dir}/${CHASE_DOSSIER_FILE}"

	[[ ! -f "$dossier" ]] && { print_error "Dossier not found: ${dossier}"; return 1; }

	local enabled
	enabled=$(jq -r '.chasers_enabled // "false"' "$dossier" 2>/dev/null) || enabled="false"

	[[ "$enabled" == "true" ]] && return 0

	if [[ "$force" == "true" ]]; then
		local force_allowed
		force_allowed=$(jq -r '.chasers_enabled // ""' "$dossier" 2>/dev/null) || force_allowed=""
		if [[ "$force_allowed" == "false-with-force-allowed" ]]; then
			print_warning "Forcing chase send (chasers_enabled: false-with-force-allowed)"
			return 0
		fi
		print_error "Chase --force requires chasers_enabled: false-with-force-allowed in dossier."
		return 1
	fi

	print_error "Case chasers are disabled. Set chasers_enabled: true in dossier.toon to enable."
	return 1
}

# =============================================================================
# Field resolution — dossier fields
# =============================================================================

_chase_dossier_parties_self() {
	local ds="$1"
	jq -r --arg r1 "$_CHASE_ROLE_SELF" --arg r2 "$_CHASE_ROLE_SENDER" --arg r3 "$_CHASE_ROLE_USER" \
		'first(.parties[] | select(.role == $r1 or .role == $r2 or .role == $r3) | .name) // ""' \
		<<< "$ds" 2>/dev/null || true
	return 0
}

_chase_dossier_parties_recipient() {
	local ds="$1"
	jq -r --arg r1 "$_CHASE_ROLE_SELF" --arg r2 "$_CHASE_ROLE_SENDER" --arg r3 "$_CHASE_ROLE_USER" \
		'first(.parties[] | select(.role != $r1 and .role != $r2 and .role != $r3) | .name) // ""' \
		<<< "$ds" 2>/dev/null || true
	return 0
}

_chase_resolve_dossier_fields() {
	local case_dir="$1" fields_json="$2"
	local dossier="${case_dir}/${CHASE_DOSSIER_FILE}"
	local ds
	ds=$(jq '.' "$dossier" 2>/dev/null) || return 1

	local case_id slug kind parties_self parties_recipient next_deadline
	case_id=$(echo "$ds" | jq -r '.id // ""')
	slug=$(echo "$ds" | jq -r '.slug // ""')
	kind=$(echo "$ds" | jq -r '.kind // ""')
	parties_self=$(_chase_dossier_parties_self "$ds")
	parties_recipient=$(_chase_dossier_parties_recipient "$ds")
	next_deadline=$(echo "$ds" | jq -r '(.deadlines | sort_by(.date) | first | .date) // ""' \
		2>/dev/null) || next_deadline=""

	fields_json=$(echo "$fields_json" | jq \
		--arg case_id "$case_id" \
		--arg slug "$slug" \
		--arg kind "$kind" \
		--arg parties_self "$parties_self" \
		--arg parties_recipient "$parties_recipient" \
		--arg next_deadline "$next_deadline" \
		'. + {case_id:$case_id, slug:$slug, kind:$kind,
		       parties_self:$parties_self,
		       parties_recipient:$parties_recipient,
		       next_deadline:$next_deadline}')
	echo "$fields_json"
	return 0
}

# =============================================================================
# Field resolution — invoice fields from attached sources
# =============================================================================

_chase_resolve_invoice_fields() {
	local case_dir="$1" fields_json="$2"
	local sources_file="${case_dir}/${CHASE_SOURCES_FILE}"

	[[ ! -f "$sources_file" ]] && { echo "$fields_json"; return 0; }

	local inv_id
	inv_id=$(jq -r 'first(.[] | select(.kind == "invoice" or .role == "invoice") | .id) // ""' \
		"$sources_file" 2>/dev/null) || inv_id=""

	[[ -z "$inv_id" ]] && { echo "$fields_json"; return 0; }

	local repo_path
	repo_path=$(dirname "$(dirname "$case_dir")")
	local extracted="${repo_path}/_knowledge/sources/${inv_id}/extracted.json"

	[[ ! -f "$extracted" ]] && { echo "$fields_json"; return 0; }

	local inv_number inv_date due_date amount currency
	inv_number=$(jq -r '.invoice_number // ""' "$extracted" 2>/dev/null) || inv_number=""
	inv_date=$(jq -r '.invoice_date // ""' "$extracted" 2>/dev/null) || inv_date=""
	due_date=$(jq -r '.due_date // ""' "$extracted" 2>/dev/null) || due_date=""
	amount=$(jq -r '.amount // ""' "$extracted" 2>/dev/null) || amount=""
	currency=$(jq -r '.currency // ""' "$extracted" 2>/dev/null) || currency=""

	fields_json=$(echo "$fields_json" | jq \
		--arg inv_number "$inv_number" \
		--arg inv_date "$inv_date" \
		--arg due_date "$due_date" \
		--arg amount "$amount" \
		--arg currency "$currency" \
		'. + {invoice_number:$inv_number, invoice_date:$inv_date,
		       due_date:$due_date, amount:$amount, currency:$currency}')
	echo "$fields_json"
	return 0
}

# =============================================================================
# Field resolution — mailbox / sender fields
# =============================================================================

_chase_read_mailbox_json() {
	local repo_path="$1" mailbox_id="$2"
	local config_file="${repo_path}/_config/mailboxes.json"

	[[ ! -f "$config_file" ]] && config_file="${HOME}/.config/aidevops/mailboxes.json"

	if [[ ! -f "$config_file" ]]; then
		print_error "mailboxes.json not found. Create at _config/mailboxes.json or ~/.config/aidevops/mailboxes.json"
		return 1
	fi

	local mailbox
	mailbox=$(jq -r --arg id "$mailbox_id" '.mailboxes[$id] // empty' "$config_file" 2>/dev/null) \
		|| mailbox=""

	if [[ -z "$mailbox" ]]; then
		print_error "Mailbox '${mailbox_id}' not found in mailboxes.json"
		return 1
	fi
	echo "$mailbox"
	return 0
}

_chase_resolve_mailbox_fields() {
	local repo_path="$1" mailbox_id="$2" fields_json="$3"
	local mb
	mb=$(_chase_read_mailbox_json "$repo_path" "$mailbox_id") || return 1

	local sender_email sender_name smtp_host smtp_port
	sender_email=$(echo "$mb" | jq -r '.email // ""')
	sender_name=$(echo "$mb" | jq -r '.display_name // ""')
	smtp_host=$(echo "$mb" | jq -r '.smtp_host // ""')
	smtp_port=$(echo "$mb" | jq -r '.smtp_port // "587"')

	fields_json=$(echo "$fields_json" | jq \
		--arg se "$sender_email" \
		--arg sn "$sender_name" \
		--arg sh "$smtp_host" \
		--arg sp "$smtp_port" \
		'. + {sender_email:$se, sender_name:$sn, smtp_host:$sh, smtp_port:$sp}')
	echo "$fields_json"
	return 0
}

# =============================================================================
# Field resolution — recipient fields
# =============================================================================

_chase_resolve_recipient_fields() {
	local case_dir="$1" to_email="$2" to_name="$3" fields_json="$4"

	if [[ -z "$to_email" ]]; then
		local dossier="${case_dir}/${CHASE_DOSSIER_FILE}"
		local ds
		ds=$(jq '.' "$dossier" 2>/dev/null) || ds="{}"
		to_email=$(echo "$ds" | jq -r --arg r1 "$_CHASE_ROLE_SELF" \
			--arg r2 "$_CHASE_ROLE_SENDER" --arg r3 "$_CHASE_ROLE_USER" \
			'first(.parties[] | select(.role != $r1 and .role != $r2 and .role != $r3) | .email // "") // ""' \
			2>/dev/null) || to_email=""
		if [[ -z "$to_name" ]]; then
			to_name=$(echo "$ds" | jq -r --arg r1 "$_CHASE_ROLE_SELF" \
				--arg r2 "$_CHASE_ROLE_SENDER" --arg r3 "$_CHASE_ROLE_USER" \
				'first(.parties[] | select(.role != $r1 and .role != $r2 and .role != $r3) | .name // "") // ""' \
				2>/dev/null) || to_name=""
		fi
	fi

	fields_json=$(echo "$fields_json" | jq \
		--arg re "$to_email" \
		--arg rn "${to_name:-}" \
		'. + {recipient_email:$re, recipient_name:$rn}')
	echo "$fields_json"
	return 0
}

# =============================================================================
# Orchestrate all field resolution
# =============================================================================

_chase_resolve_all_fields() {
	local case_dir="$1" repo_path="$2" mailbox_id="$3"
	local to_email="$4" to_name="$5"

	local fields_json="{}"
	fields_json=$(_chase_resolve_dossier_fields "$case_dir" "$fields_json") || return 1
	fields_json=$(_chase_resolve_invoice_fields "$case_dir" "$fields_json") || return 1
	fields_json=$(_chase_resolve_mailbox_fields "$repo_path" "$mailbox_id" "$fields_json") || return 1
	fields_json=$(_chase_resolve_recipient_fields "$case_dir" "$to_email" "$to_name" "$fields_json") \
		|| return 1
	echo "$fields_json"
	return 0
}

# =============================================================================
# Validate all {{placeholders}} are resolved
# =============================================================================

_chase_validate_fields() {
	local template_path="$1" fields_json="$2"
	local missing=0 missing_list=""

	while IFS= read -r placeholder; do
		[[ -z "$placeholder" ]] && continue
		local val
		val=$(echo "$fields_json" | jq -r --arg k "$placeholder" '.[$k] // ""' 2>/dev/null) \
			|| val=""
		if [[ -z "$val" ]]; then
			missing=$((missing + 1))
			missing_list="${missing_list} ${placeholder}"
		fi
	done < <(_chase_extract_placeholders "$template_path")

	if [[ $missing -gt 0 ]]; then
		print_error "Missing fields (${missing}):${missing_list}"
		print_error "Ensure dossier has parties, and invoice source has extracted.json with invoice fields."
		return 1
	fi
	return 0
}

# =============================================================================
# Dry-run output
# =============================================================================

_chase_dry_run_output() {
	local template_path="$1" fields_json="$2"
	echo "--- DRY-RUN: substituted email ---"
	python3 "${SCRIPT_DIR}/email_send.py" \
		--template "$template_path" \
		--fields-json "$fields_json" \
		--dry-run
	echo "--- END DRY-RUN ---"
	return 0
}

# =============================================================================
# SMTP credential retrieval
# =============================================================================

_chase_get_smtp_pass() {
	local repo_path="$1" mailbox_id="$2"
	local mb
	mb=$(_chase_read_mailbox_json "$repo_path" "$mailbox_id") || return 1

	local gopass_path
	gopass_path=$(echo "$mb" | jq -r '.gopass_path // ""')

	if [[ -n "$gopass_path" ]] && command -v gopass >/dev/null 2>&1; then
		gopass show -o "$gopass_path" 2>/dev/null
		return 0
	fi

	local env_key
	env_key="SMTP_PASS_$(echo "$mailbox_id" | tr '[:lower:]-' '[:upper:]_')"
	local env_val="${!env_key:-}"
	[[ -n "$env_val" ]] && echo "$env_val" && return 0

	local cred_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$cred_file" ]]; then
		# shellcheck source=/dev/null
		source "$cred_file" 2>/dev/null || true
		env_val="${!env_key:-}"
		[[ -n "$env_val" ]] && echo "$env_val" && return 0
	fi

	print_error "No SMTP password for mailbox '${mailbox_id}'. Set gopass_path or env ${env_key}."
	return 1
}

# =============================================================================
# SMTP send via email_send.py
# =============================================================================

_chase_do_smtp() {
	local template_path="$1" fields_json="$2" mailbox_id="$3" repo_path="$4"
	local mb
	mb=$(_chase_read_mailbox_json "$repo_path" "$mailbox_id") || return 1

	local smtp_host smtp_port smtp_user
	smtp_host=$(echo "$mb" | jq -r '.smtp_host // ""')
	smtp_port=$(echo "$mb" | jq -r '.smtp_port // "587"')
	smtp_user=$(echo "$mb" | jq -r '.smtp_user // ""')

	local smtp_pass
	smtp_pass=$(_chase_get_smtp_pass "$repo_path" "$mailbox_id") || return 1

	local result
	result=$(CHASE_SMTP_PASS="$smtp_pass" python3 "${SCRIPT_DIR}/email_send.py" \
		--template "$template_path" \
		--fields-json "$fields_json" \
		--smtp-host "$smtp_host" \
		--smtp-port "$smtp_port" \
		--smtp-user "$smtp_user" \
		--smtp-pass-env CHASE_SMTP_PASS 2>&1) || {
		echo "$result"
		return 1
	}
	echo "$result"
	return 0
}

# =============================================================================
# Audit — record sent email
# =============================================================================

_chase_record_sent() {
	local case_dir="$1" result_json="$2" template="$3"
	local to_email="$4" mailbox_id="$5" actor="$6"

	local ts
	ts=$(_chase_iso_ts)
	local message_id sent_at
	message_id=$(echo "$result_json" | jq -r '.message_id // ""' 2>/dev/null) || message_id=""
	sent_at=$(echo "$result_json" | jq -r '.sent_at // ""' 2>/dev/null) || sent_at="${ts}"

	mkdir -p "${case_dir}/${CHASE_COMMS_DIR}"
	local sent_log
	sent_log=$(_chase_sent_log_path "$case_dir")

	local record
	record=$(jq -cn \
		--arg ts "$ts" --arg kind "chase" --arg template "$template" \
		--arg to "$to_email" --arg mailbox "$mailbox_id" \
		--arg actor "$actor" --arg msg_id "$message_id" \
		--arg sent_at "$sent_at" --arg status "sent" \
		'{ts:$ts, kind:$kind, template:$template, to:$to, mailbox:$mailbox,
		  actor:$actor, message_id:$msg_id, sent_at:$sent_at, status:$status}')
	echo "$record" >> "$sent_log"

	local event
	event=$(jq -cn \
		--arg ts "$ts" --arg kind "comm" --arg actor "$actor" \
		--arg content "Chase sent: template=${template}, to=${to_email}, message_id=${message_id}" \
		--arg ref "${CHASE_SENT_LOGFILE}" \
		'{ts:$ts, kind:$kind, actor:$actor, content:$content, ref:$ref}')
	echo "$event" >> "${case_dir}/${CHASE_TIMELINE_FILE}"
	return 0
}

# =============================================================================
# Failure handling
# =============================================================================

_chase_record_failure() {
	local case_dir="$1" error_msg="$2" template="$3"
	local to_email="$4" actor="$5"

	local ts
	ts=$(_chase_iso_ts)
	mkdir -p "${case_dir}/${CHASE_COMMS_DIR}"

	local sent_log
	sent_log=$(_chase_sent_log_path "$case_dir")

	local record
	record=$(jq -cn \
		--arg ts "$ts" --arg kind "chase" --arg template "$template" \
		--arg to "$to_email" --arg actor "$actor" \
		--arg status "$_CHASE_STATUS_ERROR" --arg error "$error_msg" \
		'{ts:$ts, kind:$kind, template:$template, to:$to, actor:$actor,
		  status:$status, error:$error, retry_allowed:true}')
	echo "$record" >> "$sent_log"
	return 0
}

_chase_count_recent_failures() {
	local sent_log="$1"
	[[ ! -f "$sent_log" ]] && echo "0" && return 0

	local count=0 line status
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		status=$(echo "$line" | jq -r '.status // ""' 2>/dev/null) || status=""
		[[ "$status" == "$_CHASE_STATUS_ERROR" ]] && count=$((count + 1))
	done < <(tail -10 "$sent_log")
	echo "$count"
	return 0
}

_chase_trigger_hold_and_alarm() {
	local case_dir="$1" case_id="$2" repo_path="$3"
	bash "${SCRIPT_DIR}/case-helper.sh" status "$case_id" hold \
		--reason "Consecutive chase send failures" \
		--repo "$repo_path" 2>/dev/null || true

	local alarm_helper="${SCRIPT_DIR}/case-alarm-helper.sh"
	if [[ -f "$alarm_helper" ]]; then
		bash "$alarm_helper" fire "$case_id" \
			--reason "chase send failure" 2>/dev/null || true
	fi
	print_warning "Case set to hold after consecutive send failures: ${case_id}"
	return 0
}

_chase_check_consec_failures() {
	local case_dir="$1" case_id="$2" repo_path="$3"
	local sent_log
	sent_log=$(_chase_sent_log_path "$case_dir")
	local count
	count=$(_chase_count_recent_failures "$sent_log")
	[[ "$count" -ge 2 ]] && _chase_trigger_hold_and_alarm "$case_dir" "$case_id" "$repo_path"
	return 0
}

# =============================================================================
# cmd_send — send a chase email
# =============================================================================

cmd_send() {
	_chase_require_tools || return 1

	local case_id='' template='' to_email='' to_name=''
	local mailbox_id='default' dry_run=false force=false repo_path=''

	while [[ $# -gt 0 ]]; do
		local cur="${1:-}" nxt="${2:-}"
		case "$cur" in
		--template | -t) template="$nxt"; shift 2 ;;
		--to)            to_email="$nxt"; shift 2 ;;
		--to-name)       to_name="$nxt"; shift 2 ;;
		--mailbox)       mailbox_id="$nxt"; shift 2 ;;
		--dry-run)       dry_run=true; shift ;;
		--force)         force=true; shift ;;
		--repo)          repo_path="$nxt"; shift 2 ;;
		-*) print_error "Unknown option: ${cur}"; return 1 ;;
		*) case_id="$cur"; shift ;;
		esac
	done

	[[ -z "$case_id" ]] && {
		print_error "Usage: case chase <case-id> --template <name> [--to <email>] [--dry-run]"
		return 1
	}
	[[ -z "$template" ]] && { print_error "--template is required"; return 1; }
	repo_path=${repo_path:-$(pwd)}

	local case_dir
	case_dir=$(_chase_locate_case "$repo_path" "$case_id") \
		|| { _chase_err_case_not_found "$case_id"; return 1; }

	_chase_check_opt_in "$case_dir" "$force" || return 1

	local template_path
	template_path=$(_chase_find_template "$repo_path" "$template") \
		|| { print_error "Template not found: ${template}. Run: aidevops case chase-template list"; return 1; }

	local fields_json
	fields_json=$(_chase_resolve_all_fields "$case_dir" "$repo_path" "$mailbox_id" \
		"$to_email" "$to_name") || return 1

	_chase_validate_fields "$template_path" "$fields_json" || return 1

	if [[ "$dry_run" == true ]]; then
		_chase_dry_run_output "$template_path" "$fields_json"
		return 0
	fi

	local actor
	actor=$(_chase_current_actor)

	local send_result exit_code
	set +e
	send_result=$(_chase_do_smtp "$template_path" "$fields_json" "$mailbox_id" "$repo_path")
	exit_code=$?
	set -e

	if [[ $exit_code -ne 0 ]]; then
		_chase_record_failure "$case_dir" "$send_result" "$template" "$to_email" "$actor"
		_chase_check_consec_failures "$case_dir" "$case_id" "$repo_path"
		print_error "Send failed: ${send_result}"
		return 1
	fi

	_chase_record_sent "$case_dir" "$send_result" "$template" "$to_email" \
		"$mailbox_id" "$actor"
	print_success "Chase email sent: ${case_id} via ${template}"
	return 0
}

# =============================================================================
# cmd_retry — retry a failed send by message-id
# =============================================================================

cmd_retry() {
	_chase_require_tools || return 1

	local case_id="${1:-}" message_id="${2:-}"
	local mailbox_id='default' repo_path=''

	shift 2 2>/dev/null || true

	while [[ $# -gt 0 ]]; do
		local cur="${1:-}" nxt="${2:-}"
		case "$cur" in
		--mailbox) mailbox_id="$nxt"; shift 2 ;;
		--repo)    repo_path="$nxt"; shift 2 ;;
		-*) print_error "Unknown option: ${cur}"; return 1 ;;
		*) shift ;;
		esac
	done

	[[ -z "$case_id" || -z "$message_id" ]] && {
		print_error "Usage: case-chase-helper.sh retry <case-id> <message-id>"
		return 1
	}
	repo_path=${repo_path:-$(pwd)}

	local case_dir
	case_dir=$(_chase_locate_case "$repo_path" "$case_id") \
		|| { _chase_err_case_not_found "$case_id"; return 1; }

	local sent_log
	sent_log=$(_chase_sent_log_path "$case_dir")
	[[ ! -f "$sent_log" ]] && { print_error "No sent log for: ${case_id}"; return 1; }

	local record
	record=$(jq -r --arg id "$message_id" \
		'select(.message_id == $id or (.status == "error" and .ts == $id))' \
		"$sent_log" 2>/dev/null | head -1) || record=""
	[[ -z "$record" ]] && { print_error "No record found for: ${message_id}"; return 1; }

	local retry_template retry_to
	retry_template=$(echo "$record" | jq -r '.template // ""')
	retry_to=$(echo "$record" | jq -r '.to // ""')

	print_info "Retrying chase: ${case_id} template=${retry_template} to=${retry_to}"
	cmd_send "$case_id" --template "$retry_template" --to "$retry_to" \
		--mailbox "$mailbox_id" --repo "$repo_path"
	return 0
}

# =============================================================================
# Template management commands
# =============================================================================

_template_list() {
	local repo_path="$1"
	local tdir
	tdir=$(_chase_templates_dir "$repo_path")

	if [[ ! -d "$tdir" ]]; then
		echo "No templates found. Template directory: ${tdir}"
		return 0
	fi

	local count=0 f name desc
	for f in "${tdir}"/*.eml.tmpl; do
		[[ -f "$f" ]] || continue
		name=$(basename "$f" .eml.tmpl)
		desc=$(grep -m1 '^#' "$f" 2>/dev/null | sed 's/^# \{0,1\}//') || desc=""
		printf '%-30s %s\n' "$name" "${desc:-"(no description)"}"
		count=$((count + 1))
	done
	[[ $count -eq 0 ]] && echo "No .eml.tmpl files found in: ${tdir}"
	return 0
}

_template_test() {
	local repo_path="$1" case_id="$2" template="$3"
	_chase_require_tools || return 1

	local case_dir
	case_dir=$(_chase_locate_case "$repo_path" "$case_id") \
		|| { _chase_err_case_not_found "$case_id"; return 1; }

	local template_path
	template_path=$(_chase_find_template "$repo_path" "$template") \
		|| { print_error "Template not found: ${template}"; return 1; }

	local fields_json
	fields_json=$(_chase_resolve_all_fields "$case_dir" "$repo_path" "default" "" "") \
		|| return 1

	_chase_validate_fields "$template_path" "$fields_json" || return 1

	echo "--- Template test (dry-run, no send) ---"
	python3 "${SCRIPT_DIR}/email_send.py" \
		--template "$template_path" \
		--fields-json "$fields_json" \
		--dry-run
	echo "--- END ---"
	return 0
}

_template_add() {
	local repo_path="$1" name="${2:-}"

	[[ -z "$name" ]] && { print_error "Usage: case chase-template add <name>"; return 1; }

	local tdir
	tdir=$(_chase_templates_dir "$repo_path")
	mkdir -p "$tdir"

	local target="${tdir}/${name}.eml.tmpl"
	[[ -f "$target" ]] && { print_error "Template already exists: ${target}"; return 1; }

	cat > "$target" <<'TMPL'
# Description: (describe this template)
From: {{sender_email}}
To: {{recipient_email}}
Subject: (Subject line here)

Dear {{recipient_name}},

(Email body here. Use {{field}} placeholders from the dossier.)

Regards,
{{sender_name}}
TMPL

	local editor="${VISUAL:-${EDITOR:-vi}}"
	print_info "Template created: ${target}"
	print_info "Edit now with: ${editor} ${target}"
	command -v "$editor" >/dev/null 2>&1 && "$editor" "$target" || true
	return 0
}

cmd_template() {
	local action="${1:-list}"
	shift || true

	local repo_path='' case_id='' name=''

	case "$action" in
	list)
		while [[ $# -gt 0 ]]; do
			local cur="${1:-}" nxt="${2:-}"
			case "$cur" in
			--repo) repo_path="$nxt"; shift 2 ;;
			*) shift ;;
			esac
		done
		repo_path=${repo_path:-$(pwd)}
		_template_list "$repo_path"
		;;
	test)
		while [[ $# -gt 0 ]]; do
			local cur="${1:-}" nxt="${2:-}"
			case "$cur" in
			--case)     case_id="$nxt"; shift 2 ;;
			--template) name="$nxt"; shift 2 ;;
			--repo)     repo_path="$nxt"; shift 2 ;;
			*) shift ;;
			esac
		done
		repo_path=${repo_path:-$(pwd)}
		[[ -z "$case_id" || -z "$name" ]] && {
			print_error "Usage: case chase-template test --case <id> --template <name>"
			return 1
		}
		_template_test "$repo_path" "$case_id" "$name"
		;;
	add)
		while [[ $# -gt 0 ]]; do
			local cur="${1:-}" nxt="${2:-}"
			case "$cur" in
			--repo) repo_path="$nxt"; shift 2 ;;
			-*) shift ;;
			*) name="$cur"; shift ;;
			esac
		done
		repo_path=${repo_path:-$(pwd)}
		_template_add "$repo_path" "$name"
		;;
	*) print_error "Usage: case chase-template add|list|test [options]"; return 1 ;;
	esac
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
Case Chase Helper (t2858) — template-only, opt-in chaser emails

Usage: case-chase-helper.sh <command> [args] [options]

Commands:
  send <case-id> --template <name>    Send a chase email (opt-in required)
  retry <case-id> <message-id>        Retry a failed send
  template list                        List available templates
  template add <name>                  Create a new template (opens editor)
  template test --case <id> --template <name>   Dry-run substitution (no send)
  help                                 Show this help

send options:
  --template <name>    Template name (from _config/case-chase-templates/)
  --to <email>         Recipient email (auto-detected from dossier if omitted)
  --to-name <name>     Recipient name override
  --mailbox <id>       Mailbox ID from mailboxes.json (default: "default")
  --dry-run            Print substituted email to stdout, no SMTP call
  --force              Override opt-in (requires chasers_enabled: false-with-force-allowed)
  --repo <path>        Target repo path (default: current directory)

Opt-in:
  Set chasers_enabled: true in _cases/<id>/dossier.toon to enable chase sends.
  Defaults to false. Explicit opt-in per case is required.

Templates:
  Stored in _config/case-chase-templates/<name>.eml.tmpl
  Use {{field}} placeholders: sender_email, sender_name, recipient_email,
  recipient_name, invoice_number, invoice_date, due_date, amount, currency,
  case_id, slug, next_deadline, parties_self, parties_recipient.

Examples:
  case-chase-helper.sh send case-2026-0001-acme --template payment-reminder --dry-run
  case-chase-helper.sh send case-2026-0001-acme --template payment-reminder
  case-chase-helper.sh template list
  case-chase-helper.sh template test --case case-2026-0001-acme --template payment-reminder
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
	send)     cmd_send "$@" ;;
	retry)    cmd_retry "$@" ;;
	template) cmd_template "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
